import SwiftUI

#if os(macOS)
struct CustomStatusBar: View {
    var body: some View {
        EmptyView()
    }
}
#else
struct CustomStatusBar: View {
    @State private var currentTime: String = ""
    @State private var batteryLevel: Float = 1.0
    @State private var batteryState: UIDevice.BatteryState = .unplugged
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // Time in Center
            Text(currentTime)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            
            // Battery on Trailing Edge
            HStack(spacing: 4) {
                Spacer()
                
                Text("\(Int(batteryLevel * 100))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                
                // Custom Battery Icon
                HStack(spacing: 1) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                            .frame(width: 20, height: 10)
                        
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(batteryColor)
                            .frame(width: max(0, min(CGFloat(batteryLevel) * 16, 16)), height: 6)
                            .padding(.leading, 2)
                        
                        if batteryState == .charging || batteryState == .full {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 6, weight: .black))
                                .foregroundColor(batteryColor == .white ? .black : .white)
                                .frame(width: 20, height: 10, alignment: .center)
                        }
                    }
                    
                    // Battery knob
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 3))
                        path.addCurve(to: CGPoint(x: 0, y: 7), control1: CGPoint(x: 1.5, y: 3), control2: CGPoint(x: 1.5, y: 7))
                    }
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    .frame(width: 1.5, height: 10)
                }
            }
        }
        .frame(height: 14)
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            updateTime()
            updateBattery()
            NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { _ in updateBattery() }
            NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in updateBattery() }
        }
        .onReceive(timer) { _ in
            updateTime()
        }
    }
    
    private var batteryColor: Color {
        if batteryState == .charging || batteryState == .full { return .green }
        if batteryLevel <= 0.2 && batteryLevel >= 0 { return .red }
        return .white
    }
    
    private func updateTime() {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        currentTime = formatter.string(from: Date())
    }
    
    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level < 0 ? 1.0 : level // Simulator fallback is -1.0
        batteryState = UIDevice.current.batteryState
    }
}

#endif
