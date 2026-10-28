/// A complete Moonlight controller state. Positive Y points up on both APIs.
public struct ControllerState: Sendable, Equatable {
    public var buttons: UInt32
    public var leftTrigger: UInt8, rightTrigger: UInt8
    public var leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16
    public init(buttons: UInt32 = 0, leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0,
                leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0) {
        self.buttons=buttons;self.leftTrigger=leftTrigger;self.rightTrigger=rightTrigger
        self.leftX=leftX;self.leftY=leftY;self.rightX=rightX;self.rightY=rightY
    }
    public static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 };return UInt8((min(1,max(0,value))*255).rounded())
    }
    /// Radial 12% dead zone, rescaled to preserve full travel; clamps invalid device input.
    public static func stick(x: Float,y: Float) -> (Int16,Int16) {
        guard x.isFinite,y.isFinite else { return (0,0) }
        let x=Double(min(1,max(-1,x))),y=Double(min(1,max(-1,y)))
        let magnitude=(x*x+y*y).squareRoot()
        guard magnitude > 0.12 else { return (0,0) }
        let scale=(min(1,magnitude)-0.12)/0.88/magnitude
        func axis(_ value: Double) -> Int16 { Int16((value * (value < 0 ? 32768 : 32767)).rounded()) }
        return (axis(x*scale),axis(y*scale))
    }
}
