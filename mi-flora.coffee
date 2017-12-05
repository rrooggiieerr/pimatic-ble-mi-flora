module.exports = (env) ->
  Promise = env.require 'bluebird'

  events = require 'events'

  class MiFloraPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>
      @devices = {}

      deviceConfigDef = require('./device-config-schema')
      @framework.deviceManager.registerDeviceClass('MiFloraDevice', {
        configDef: deviceConfigDef.MiFloraDevice,
        createCallback: (config, lastState) =>
          device = new MiFloraDevice(config, @, lastState)
          @addToScan config.uuid, device
          return device
      })

      @framework.deviceManager.on 'discover', (eventData) =>
          @framework.deviceManager.discoverMessage 'pimatic-mi-flora', 'Scanning for Mi Flora plant sensors'

          @ble.on 'discover-mi-flora', (peripheral) =>
            env.logger.debug 'Device %s found, state: %s', peripheral.uuid, peripheral.state
            config = {
              class: 'MiFloraDevice',
              uuid: peripheral.uuid
            }
            @framework.deviceManager.discoveredDevice(
              'pimatic-mi-flora', 'Mi Flora plant sensor ' + peripheral.uuid, config
            )

      @framework.on 'after init', =>
        @ble = @framework.pluginManager.getPlugin 'ble'
        if @ble?
          @ble.registerName 'Flower mate', 'mi-flora'
          @ble.registerName 'Flower care', 'mi-flora'

          for uuid, device of @devices
            @ble.on 'discover-' + uuid, (peripheral) =>
              device = @devices[peripheral.uuid]
              env.logger.debug 'Device %s found, state: %s', device.name, peripheral.state
              #@removeFromScan peripheral.uuid
              device.connect peripheral
            @ble.addToScan uuid, device
        else
          env.logger.warn 'mi-flora could not find ble. It will not be able to discover devices'

    addToScan: (uuid, device) =>
      env.logger.debug 'Adding device %s', uuid
      if @ble?
        @ble.on 'discover-' + uuid, (peripheral) =>
          device = @devices[peripheral.uuid]
          env.logger.debug 'Device %s found, state: %s', device.name, peripheral.state
          #@removeFromScan peripheral.uuid
          device.connect peripheral
        @ble.addToScan uuid, device
      @devices[uuid] = device

    removeFromScan: (uuid) =>
      env.logger.debug 'Removing device %s', uuid
      if @ble?
        @ble.removeFromScan uuid
      if @devices[uuid]
        delete @devices[uuid]

  class MiFloraDevice extends env.devices.TemperatureSensor
    attributes:
      temperature:
        description: 'The measured temperature'
        type: 'number'
        unit: '°C'
        acronym: 'T'
      light:
        description: 'The measured brightness'
        type: 'number'
        unit: 'lx'
        acronym: '☀️'
      moisture:
        description: 'The measured moisture level'
        type: 'number'
        unit: '%'
        acronym: '💦'
      fertility:
        description: 'The measured fertility level'
        type: 'number'
        unit: 'µS/cm'
      battery:
        description: 'Battery status'
        type: 'number'
        unit: '%'
        acronym: '🔋'
      presence:
        description: 'Presence of the plant sensor'
        type: 'boolean'
        labels: ['present', 'absent']

    actions:
      getPresence:
        description: 'Returns the current presence state'
        returns:
          presence:
            type: 'boolean'

    DATA_SERVICE_UUID = '0000120400001000800000805f9b34fb'
    DATA_CHARACTERISTIC_UUID = '00001a0100001000800000805f9b34fb'
    FIRMWARE_CHARACTERISTIC_UUID = '00001a0200001000800000805f9b34fb'
    REALTIME_CHARACTERISTIC_UUID = '00001a0000001000800000805f9b34fb'
    REALTIME_META_VALUE = Buffer.from([ 0xA0, 0x1F ])
    SERVICE_UUIDS = [ DATA_SERVICE_UUID ]
    CHARACTERISTIC_UUIDS = [ DATA_CHARACTERISTIC_UUID, FIRMWARE_CHARACTERISTIC_UUID, REALTIME_CHARACTERISTIC_UUID ]

    constructor: (@config, plugin, lastState) ->
      @id = @config.id
      @name = @config.name
      @interval = @config.interval
      @uuid = @config.uuid
      @peripheral = null
      @plugin = plugin

      @_temperature = lastState?.temperature?.value or 0.0
      @_light = lastState?.light?.value or 0
      @_moisture = lastState?.moisture?.value or 0
      @_fertility = lastState?.fertility?.value or 0
      @_battery = lastState?.battery?.value or 0.0
      @_presence = lastState?.presence?.value or false

      super()

    connect: (peripheral) ->
      @peripheral = peripheral

      @peripheral.on 'disconnect', (error) =>
        env.logger.debug 'Device %s disconnected', @name

      clearInterval @reconnectInterval
      if @_destroyed then return
      @reconnectInterval = setInterval( =>
        @_connect()
      , @interval)
      @_connect()

    _connect: ->
      if @_destroyed then return
      if @peripheral.state == 'disconnected'
        env.logger.debug 'Trying to connect to %s', @name
        @plugin.ble.stopScanning()
        @peripheral.connect (error) =>
          if !error
            env.logger.debug 'Device %s connected', @name
            @_setPresence true
            @readData @peripheral
          else
            env.logger.debug 'Device %s connection failed: %s', @name, error
            @_setPresence false
          @plugin.ble.startScanning()

    _setPresence: (value) ->
      if @_presence is value then return
      @_presence = value
      @emit 'presence', value

    readData: (peripheral) ->
      env.logger.debug 'Reading data from %s', @name
      peripheral.discoverSomeServicesAndCharacteristics @SERVICE_UUIDS, @CHARACTERISTIC_UUIDS, (error, services, characteristics) =>
        characteristics.forEach (characteristic) =>
          switch characteristic.uuid
            when DATA_CHARACTERISTIC_UUID
              characteristic.read (error, data) =>
                @parseData peripheral, data
            when FIRMWARE_CHARACTERISTIC_UUID
              characteristic.read (error, data) =>
                @parseFirmwareData peripheral, data
            when REALTIME_CHARACTERISTIC_UUID
              env.logger.debug 'enabling realtime'
              characteristic.write REALTIME_META_VALUE, false
            #else
            #  characteristic.read (error, data) =>
            #    env.logger.debug 'found characteristic uuid %s but not matched the criteria', characteristic.uuid
            #    env.logger.debug '%s: %s (%s)', characteristic.uuid, data, error

    parseData: (peripheral, data) ->
      @_setTemperature data.readUInt16LE(0) / 10
      @_light = data.readUInt32LE(3)
      @emit 'light', @_light
      @_moisture = data.readUInt16BE(6)
      @emit 'moisture', @_moisture
      @_fertility = data.readUInt16LE(8)
      @emit 'fertility', @_fertility
      env.logger.debug 'temperature: %s °C', @_temperature
      env.logger.debug 'Light: %s lux', @_light
      env.logger.debug 'moisture: %s%', @_moisture
      env.logger.debug 'fertility: %s µS/cm', @_fertility

    parseFirmwareData: (peripheral, data) ->
      @_firmware = data.toString('ascii', 2, data.length)
      @_battery = parseInt(data.toString('hex', 0, 1), 16)
      @emit 'battery', @_battery
      env.logger.debug 'firmware: %s', @_firmware
      env.logger.debug 'battery: %s%', @_battery
    
    destroy: ->
      env.logger.debug 'Destroy %s', @name
      @_destroyed = true
      @emit('destroy', @)
      @removeAllListeners('destroy')
      @removeAllListeners(attrName) for attrName of @attributes

      if @peripheral && @peripheral.state == 'connected'
        @peripheral.disconnect()
      @plugin.removeFromScan @uuid
      super()

      clearInterval(@reconnectInterval)

    getLight: -> Promise.resolve @_light
    getMoisture: -> Promise.resolve @_moisture
    getFertility: -> Promise.resolve @_fertility
    getBattery: -> Promise.resolve @_battery
    getPresence: -> Promise.resolve(@_presence)

  return new MiFloraPlugin
