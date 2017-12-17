module.exports ={
  title: "pimatic-ble-mi-flora device config schemas"
  MiFloraDevice: {
    title: "Xiaomi Mi Flora config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      uuid:
        description: "uuid of the Mi Flora to connect"
        type: "string"
      interval:
        description: "Interval between requests"
        type: "number"
        default: 300000
  }
}
