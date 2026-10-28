import Foundation
import Observation
import StorageCore

/// The tabs of one window and the conflict prompt they share.
@Observable
final class BrowserWindowModel {
    private(set) var tabs: [BrowserTab] = []
    var selectedTabID: BrowserTab.ID?
    let conflicts = ConflictResolver()

    @ObservationIgnored private let pool: ConnectionPool
    @ObservationIgnored private let transfers: TransferQueue

    init(pool: ConnectionPool, transfers: TransferQueue) {
        self.pool = pool
        self.transfers = transfers
        let tab = BrowserTab(pool: pool, transfers: transfers)
        tabs = [tab]
        selectedTabID = tab.id
    }

    var currentTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    @discardableResult
    func newTab(opening profile: ConnectionProfile? = nil, at path: RemotePath? = nil) -> BrowserTab {
        let tab = BrowserTab(pool: pool, transfers: transfers)
        tabs.append(tab)
        selectedTabID = tab.id
        if let profile {
            tab.open(profile, at: path)
        }
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
        } else if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Opens a connection in the current tab.
    func open(_ profile: ConnectionProfile, at path: RemotePath? = nil) {
        let tab = currentTab ?? newTab()
        tab.open(profile, at: path)
    }

    func profileDidChange(_ profile: ConnectionProfile) {
        tabs.forEach { $0.profileDidChange(profile) }
    }
}
