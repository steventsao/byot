import SwiftUI
import WidgetKit

@main
struct BYOTWidgetBundle: WidgetBundle {
    var body: some Widget {
        BYOTSessionsWidget()
        BYOTTurnLiveActivity()
    }
}
