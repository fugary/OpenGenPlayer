import SwiftUI
import GenPlayerCore

#if os(iOS)
/// Page-local search: the navigation bar stays owned by the original page.
struct LibraryInlineSearchModifier<ResultsContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var query: String
    let placeholder: String
    let serverId: String
    var onSubmit: ((String) -> Void)? = nil
    @ViewBuilder var resultsContent: () -> ResultsContent

    @ObservedObject private var historyService = SearchHistoryService.shared

    private var showsResults: Bool {
        isPresented && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recentQueryCount: Int {
        historyService.historyByServer[serverId]?.count ?? 0
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if isPresented {
                if !showsResults && recentQueryCount > 0 {
                    ScrollView {
                        RecentSearchesSection(serverId: serverId) { selectedQuery in
                            query = selectedQuery
                            onSubmit?(selectedQuery)
                        }
                    }
                    .frame(height: min(CGFloat(recentQueryCount) * 48 + 56, 180))
                }
            }

            ZStack(alignment: .top) {
                // Keep the browsing instance and scroll position while showing results.
                content
                    .opacity(showsResults ? 0 : 1)
                    .allowsHitTesting(!showsResults)
                    .accessibilityHidden(showsResults)

                if showsResults {
                    ScrollView {
                        resultsContent()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .padding(.bottom, 24)
                    }
                    .scrollDismissesKeyboardCompat()
                    .transaction { $0.animation = nil }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            LibraryNativeSearchController(
                isPresented: $isPresented,
                query: $query,
                placeholder: placeholder,
                onSubmit: onSubmit
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if isPresented { _ = historyService.getHistory(for: serverId) }
        }
        .onChange(of: isPresented) { presented in
            if presented {
                _ = historyService.getHistory(for: serverId)
            } else {
                query = ""
            }
        }
        .keepLibrarySearchBarVisibleCompat()
    }
}

/// Let UIKit own the search button, field, material, and both transition directions.
/// This bridge is local to iOS media libraries and IPTV; file-page search is unchanged.
private struct LibraryNativeSearchController: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var query: String
    let placeholder: String
    var onSubmit: ((String) -> Void)?

    func makeUIViewController(context: Context) -> SearchHost {
        let host = SearchHost()
        updateUIViewController(host, context: context)
        return host
    }

    func updateUIViewController(_ host: SearchHost, context: Context) {
        host.presented = $isPresented
        host.query = $query
        host.placeholder = placeholder
        host.onSubmit = onSubmit
        host.scheduleUpdate()
    }

    static func dismantleUIViewController(_ host: SearchHost, coordinator: ()) {
        host.detach()
    }

    final class SearchHost: UIViewController, UISearchResultsUpdating, UISearchBarDelegate, UISearchControllerDelegate {
        var presented: Binding<Bool> = .constant(false)
        var query: Binding<String> = .constant("")
        var placeholder = ""
        var onSubmit: ((String) -> Void)?

        private weak var owner: UIViewController?
        private var updateWork: DispatchWorkItem?
        private var legacyActivationWork: DispatchWorkItem?
        private var isLeavingPage = false
        private var hasAppeared = false
        private var restoresWithoutKeyboard = false
        private var previousSearchController: UISearchController?
        private var previousPresentationContext = false
        private var previousHidesSearchBar = true
        private var previousPlacement: Int?
        private var previousToolbarIntegration = true
        private var previousPinnedGroup: UIBarButtonItemGroup?
        private var pinnedActions: UIBarButtonItemGroup?
        private var originalRightItems: [UIBarButtonItem]?
        private var previousStandardAppearance: UINavigationBarAppearance?
        private var previousScrollEdgeAppearance: UINavigationBarAppearance?
        private var previousCompactAppearance: UINavigationBarAppearance?
        private var previousCompactScrollEdgeAppearance: UINavigationBarAppearance?

        private lazy var search: UISearchController = {
            let controller = UISearchController(searchResultsController: nil)
            controller.obscuresBackgroundDuringPresentation = false
            controller.hidesNavigationBarDuringPresentation = false
            controller.searchResultsUpdater = self
            controller.delegate = self
            controller.searchBar.delegate = self
            controller.searchBar.searchBarStyle = .minimal
            controller.searchBar.autocapitalizationType = .none
            controller.searchBar.autocorrectionType = .no
            return controller
        }()

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            scheduleUpdate()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isLeavingPage = false
            restoresWithoutKeyboard = hasAppeared && presented.wrappedValue
            hasAppeared = true
            scheduleUpdate()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isLeavingPage = true
            updateWork?.cancel()
            legacyActivationWork?.cancel()
            if #unavailable(iOS 26.0) {
                search.searchBar.searchTextField.resignFirstResponder()
            }
        }

        func scheduleUpdate() {
            updateWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.updateSearch() }
            updateWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func updateSearch() {
            guard !isLeavingPage, let host = pageController() else { return }
            if #unavailable(iOS 26.0) {
                guard presented.wrappedValue else {
                    if search.isActive { search.isActive = false }
                    else { detach() }
                    return
                }
            }
            if owner !== host || host.navigationItem.searchController !== search {
                detach()
                owner = host
                previousSearchController = host.navigationItem.searchController
                previousPresentationContext = host.definesPresentationContext
                previousHidesSearchBar = host.navigationItem.hidesSearchBarWhenScrolling
                host.definesPresentationContext = true
                host.navigationItem.hidesSearchBarWhenScrolling = false
                if #available(iOS 16.0, *) {
                    previousPlacement = host.navigationItem.preferredSearchBarPlacement.rawValue
                }
                if #available(iOS 26.0, *) {
                    previousToolbarIntegration = host.navigationItem.searchBarPlacementAllowsToolbarIntegration
                    previousPinnedGroup = host.navigationItem.pinnedTrailingGroup
                    host.navigationItem.searchBarPlacementAllowsToolbarIntegration = false
                    host.navigationItem.preferredSearchBarPlacement = .integratedButton
                } else if #available(iOS 16.0, *) {
                    host.navigationItem.preferredSearchBarPlacement = .stacked
                }
                if #unavailable(iOS 26.0) {
                    // Legacy stacked search needs its own readable navigation surface,
                    // even when the browsing page uses a transparent hero header.
                    let item = host.navigationItem
                    previousStandardAppearance = item.standardAppearance
                    previousScrollEdgeAppearance = item.scrollEdgeAppearance
                    previousCompactAppearance = item.compactAppearance
                    previousCompactScrollEdgeAppearance = item.compactScrollEdgeAppearance
                    let appearance = UINavigationBarAppearance()
                    appearance.configureWithOpaqueBackground()
                    item.standardAppearance = appearance
                    item.scrollEdgeAppearance = appearance
                    item.compactAppearance = appearance
                    item.compactScrollEdgeAppearance = appearance
                }
                host.navigationItem.searchController = search
            }
            keepActionsAfterSearch(in: host.navigationItem)
            search.searchBar.placeholder = placeholder
            if search.searchBar.text != query.wrappedValue {
                search.searchBar.text = query.wrappedValue
            }
            if search.isActive != presented.wrappedValue {
                if #unavailable(iOS 26.0), presented.wrappedValue {
                    // A newly installed stacked bar must be laid out before activation.
                    legacyActivationWork?.cancel()
                    let work = DispatchWorkItem { [weak self, weak host] in
                        guard let self, let host, !self.isLeavingPage,
                              self.presented.wrappedValue,
                              host.navigationItem.searchController === self.search else { return }
                        host.navigationController?.navigationBar.layoutIfNeeded()
                        self.search.isActive = true
                    }
                    legacyActivationWork = work
                    DispatchQueue.main.async(execute: work)
                } else {
                    search.isActive = presented.wrappedValue
                }
            }
        }

        func updateSearchResults(for searchController: UISearchController) {
            let text = searchController.searchBar.text ?? ""
            if query.wrappedValue != text { query.wrappedValue = text }
        }

        func willPresentSearchController(_ searchController: UISearchController) {
            if !presented.wrappedValue { presented.wrappedValue = true }
        }

        func didPresentSearchController(_ searchController: UISearchController) {
            if restoresWithoutKeyboard {
                restoresWithoutKeyboard = false
                if #unavailable(iOS 26.0) {
                    searchController.searchBar.searchTextField.resignFirstResponder()
                } else {
                    searchController.searchBar.resignFirstResponder()
                }
            } else if #unavailable(iOS 26.0) {
                // On iOS 16 the search bar itself can reject first responder during
                // this callback. Focus its installed text field after presentation.
                DispatchQueue.main.async { [weak self, weak searchController] in
                    guard let self, let searchController, !self.isLeavingPage,
                          self.presented.wrappedValue, searchController.isActive else { return }
                    searchController.searchBar.searchTextField.becomeFirstResponder()
                }
            }
        }

        func didDismissSearchController(_ searchController: UISearchController) {
            guard !isLeavingPage else { return }
            if presented.wrappedValue { presented.wrappedValue = false }
            if !query.wrappedValue.isEmpty { query.wrappedValue = "" }
            if #unavailable(iOS 26.0) {
                restoresWithoutKeyboard = false
                detach()
            }
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            let text = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSubmit?(text) }
            if #unavailable(iOS 26.0) {
                searchBar.searchTextField.resignFirstResponder()
            } else {
                searchBar.resignFirstResponder()
            }
        }

        private func keepActionsAfterSearch(in item: UINavigationItem) {
            guard #available(iOS 26.0, *), let actions = item.rightBarButtonItems,
                  !actions.isEmpty else { return }
            // A native pinned trailing group is placed AFTER the integrated search.
            // Keep the same Button/Menu items and their actions; only their native
            // placement changes. The search controller remains installed so UIKit
            // can morph its existing button without a mount/layout gap.
            originalRightItems = actions
            item.rightBarButtonItems = nil
            let group = pinnedActions ?? UIBarButtonItemGroup(barButtonItems: [], representativeItem: nil)
            group.barButtonItems = Array(actions.reversed())
            pinnedActions = group
            item.pinnedTrailingGroup = group
        }

        func detach() {
            updateWork?.cancel()
            legacyActivationWork?.cancel()
            guard let owner, owner.navigationItem.searchController === search else { return }
            owner.navigationItem.searchController = previousSearchController
            owner.definesPresentationContext = previousPresentationContext
            owner.navigationItem.hidesSearchBarWhenScrolling = previousHidesSearchBar
            if #unavailable(iOS 26.0) {
                owner.navigationItem.standardAppearance = previousStandardAppearance
                owner.navigationItem.scrollEdgeAppearance = previousScrollEdgeAppearance
                owner.navigationItem.compactAppearance = previousCompactAppearance
                owner.navigationItem.compactScrollEdgeAppearance = previousCompactScrollEdgeAppearance
            }
            if #available(iOS 16.0, *), let rawValue = previousPlacement,
               let placement = UINavigationItem.SearchBarPlacement(rawValue: rawValue) {
                owner.navigationItem.preferredSearchBarPlacement = placement
            }
            if #available(iOS 26.0, *) {
                owner.navigationItem.searchBarPlacementAllowsToolbarIntegration = previousToolbarIntegration
                if owner.navigationItem.pinnedTrailingGroup === pinnedActions {
                    owner.navigationItem.pinnedTrailingGroup = previousPinnedGroup
                    if owner.navigationItem.rightBarButtonItems?.isEmpty != false {
                        owner.navigationItem.rightBarButtonItems = originalRightItems
                    }
                }
                pinnedActions = nil
                originalRightItems = nil
            }
            self.owner = nil
        }

        private func pageController() -> UIViewController? {
            var ancestor = parent
            while let controller = ancestor {
                if let navigation = controller.navigationController,
                   navigation.viewControllers.contains(where: { $0 === controller }) {
                    return controller
                }
                ancestor = controller.parent
            }
            return nil
        }
    }
}

private extension View {
    @ViewBuilder
    func keepLibrarySearchBarVisibleCompat() -> some View {
        if #available(iOS 27.0, *) {
            // The bar can minimize independently of hidesSearchBarWhenScrolling.
            // Keep the existing integrated search reachable at every scroll offset.
            self.toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollDismissesKeyboardCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
    }
}
#endif
