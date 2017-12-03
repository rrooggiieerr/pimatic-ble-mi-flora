module.exports = (env) ->
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'

  events = require 'events'

  class MiFloraPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>
      deviceConfigDef = require('./device-config-schema')
      @devices = []

      @framework.deviceManager.registerDeviceClass('MiFloraDevice', {
        configDef: deviceConfigDef.MiFloraDevice,
        createCallback: (config, lastState) =>
          @addOnScan config.uuid
          return new MiFloraDevice(config, @, lastState)
      })

      @framework.on 'after init', =>
        @ble = @framework.pluginManager.getPlugin 'ble'
        if @ble?
          @ble.registerName 'Flower mate'
          @ble.registerName 'Flower care'

          @ble.addOnScan device for device in @devices

          @ble.on('discover', (peripheral) =>
            @emit 'discover-' + peripheral.uuid, peripheral
          )
        else
          env.logger.warn 'mi-flora could not find ble. It will not be able to discover devices'

    addOnScan: (uuid) =>
      env.logger.debug 'Adding device %s', uuid
      if @ble?
        @ble.addOnScan uuid
      else
        @devices.push uuid

    removeFromScan: (uuid) =>
      env.logger.debug 'Removing device ', uuid
      if @ble?
        @ble.removeFromScan uuid
      else
        @devices.splice @devices.indexOf(uuid), 1

  class MiFloraDevice extends env.devices.Sensor
    attributes:
      temperature:
        description: ''
        type: 'number'
        unit: '°C'
      light:
        description: ''
        type: 'number'
        unit: 'lx'
      moisture:
        description: ''
        type: 'number'
        unit: '%'
      fertility:
        description: ''
        type: 'number'
        unit: 'µS/cm'
      battery:
        description: 'State of battery'
        type: 'number'
        unit: '%'

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

      @temperature = lastState?.temperature?.value or 0.0
      @light = lastState?.light?.value or 0
      @moisture = lastState?.moisture?.value or 0
      @fertility = lastState?.fertility?.value or 0
      @battery = lastState?.battery?.value or 0.0

      super()

      @plugin.on('discover-' + @uuid, (peripheral) =>
        env.logger.debug 'Device %s found, state: %s', @name, peripheral.state
        @connect peripheral
      )

    connect: (peripheral) ->
      @peripheral = peripheral
      @plugin.removeFromScan @uuid

      @peripheral.on 'disconnect', (error) =>
        env.logger.debug 'Device %s disconnected', @name

      setInterval( =>
        @_connect()
      , @interval)

      @_connect()

    _connect: ->
      if @peripheral.state == 'disconnected'
        @plugin.ble.stopScanning()
        @peripheral.connect (error) =>
          if !error
            env.logger.debug 'Device %s connected', @name
            @plugin.ble.startScanning()
            @readData @peripheral
          else
            env.logger.debug 'Device %s connection failed: %s', @name, error

    readData: (peripheral) ->
      env.logger.debug 'readData'
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
      @temperature = data.readUInt16LE(0) / 10
      @light = data.readUInt32LE(3)
      @moisture = data.readUInt16BE(6)
      @fertility = data.readUInt16LE(8)
      env.logger.debug 'temperature: %s °C', @temperature
      env.logger.debug 'Light: %s lux', @light
      env.logger.debug 'moisture: %s%', @moisture
      env.logger.debug 'fertility: %s µS/cm', @fertility
      @emit 'temperature', @temperature
      @emit 'light', @light
      @emit 'moisture', @moisture
      @emit 'fertility', @fertility

    parseFirmwareData: (peripheral, data) ->
      @battery = parseInt(data.toString('hex', 0, 1), 16)
      @firmware = data.toString('ascii', 2, data.length)
      env.logger.debug 'firmware: %s', @firmware
      env.logger.debug 'battery: %s%', @battery
      @emit 'battery', @battery
    
    destroy: ->
      @plugin.removeFromScan @uuid
      super()

    getTemperature: -> Promise.resolve @temperature
    getLight: -> Promise.resolve @light
    getMoisture: -> Promise.resolve @moisture
    getFertility: -> Promise.resolve @fertility
    getBattery: -> Promise.resolve @battery

  return new MiFloraPlugin
