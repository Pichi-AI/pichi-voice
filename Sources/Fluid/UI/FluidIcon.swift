import SwiftUI

struct FluidIcon: View {
    let size: CGFloat
    let lineWidth: CGFloat
    let color: Color

    init(size: CGFloat = 24, lineWidth: CGFloat = 2.5, color: Color = .white) {
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    var body: some View {
        PichiBrandMark(size: self.size, color: self.color)
    }
}

// Variants for different use cases
struct FluidIconFilled: View {
    let size: CGFloat
    let color: Color
    let backgroundColor: Color
    let cornerRadius: CGFloat

    init(size: CGFloat = 32, color: Color = .white, backgroundColor: Color = .blue, cornerRadius: CGFloat = 8) {
        self.size = size
        self.color = color
        self.backgroundColor = backgroundColor
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.cornerRadius)
                .fill(self.backgroundColor)
                .frame(width: self.size, height: self.size)

            FluidIcon(size: self.size * 0.6, lineWidth: self.size * 0.08, color: self.color)
        }
    }
}

// Advanced variant with sophisticated negative space
struct FluidIconAdvanced: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 24, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        PichiBrandMark(size: self.size, color: self.color)
    }
}

// Preview for development
#Preview("Fluid Icon Variants") {
    VStack(spacing: 20) {
        Text("Standard Geometric F")
            .font(.fluidSystem(.headline))

        HStack(spacing: 20) {
            FluidIcon(size: 24, color: .white)
                .background(Color.black.opacity(0.3))

            FluidIcon(size: 32, color: .blue)

            FluidIcon(size: 48, color: .primary)
        }

        Text("Advanced Angular F")
            .font(.fluidSystem(.headline))

        HStack(spacing: 20) {
            FluidIconAdvanced(size: 24, color: .white)
                .background(Color.black.opacity(0.3))

            FluidIconAdvanced(size: 32, color: .blue)

            FluidIconAdvanced(size: 48, color: .primary)
        }

        HStack(spacing: 20) {
            FluidIconFilled(size: 32, backgroundColor: .blue)
            FluidIconFilled(size: 40, backgroundColor: .purple)
            FluidIconFilled(size: 48, backgroundColor: Color.fluidGreen)
        }

        // Large version for app icon
        FluidIconFilled(size: 80, backgroundColor: .black, cornerRadius: 16)
    }
    .padding()
    .background(Color.gray.opacity(0.1))
}
