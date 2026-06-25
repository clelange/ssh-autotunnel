import Foundation
import SwiftUI

struct DashboardProfileSelectionRequest: Identifiable, Equatable {
    let id = UUID()
    let profileID: UUID
}

final class DashboardNavigationRequest: ObservableObject {
    static let shared = DashboardNavigationRequest()

    @Published private(set) var pendingProfileSelection: DashboardProfileSelectionRequest?

    private init() {}

    func selectProfile(_ profileID: UUID) {
        pendingProfileSelection = DashboardProfileSelectionRequest(profileID: profileID)
    }

    func clear(_ request: DashboardProfileSelectionRequest) {
        guard pendingProfileSelection?.id == request.id else { return }
        pendingProfileSelection = nil
    }
}
