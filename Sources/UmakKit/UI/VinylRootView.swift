import SwiftUI

struct NotchHoverView: View {
    let armed: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear

            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.10), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 42
                        )
                    )
                    .frame(width: 84, height: 7)
                    .blur(radius: 1.2)
                    .offset(y: 1.5)

                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0.0),
                                .init(color: .white.opacity(0.20), location: 0.5),
                                .init(color: .white.opacity(0), location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }
            .opacity(armed ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: armed)
        }
    }
}

struct VinylRootView: View {
    @ObservedObject var model: VinylViewModel
    let hover: RecordHoverModel
    let layout: VinylLayout

    var body: some View {
        ZStack {
            if model.showStage {
                VinylStageView(model: model, hover: hover, layout: layout)
            } else {
                NotchHoverView(armed: model.showHoverCue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea()
    }
}
