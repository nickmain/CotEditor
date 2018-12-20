//
//  DocumentViewController.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2016-06-05.
//
//  ---------------------------------------------------------------------------
//
//  © 2004-2007 nakamuxu
//  © 2014-2018 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Cocoa

private let maximumNumberOfSplitEditors = 8


final class DocumentViewController: NSSplitViewController, NSMenuItemValidation, SyntaxParserDelegate, ThemeHolder, NSTextStorageDelegate {
    
    // MARK: Private Properties
    
    private var appearanceObserver: NSKeyValueObservation?
    private weak var syntaxHighlightProgress: Progress?
    
    @IBOutlet private weak var splitViewItem: NSSplitViewItem?
    @IBOutlet private weak var statusBarItem: NSSplitViewItem?
    
    
    
    // MARK: -
    // MARK: Split View Controller Methods
    
    deinit {
        self.appearanceObserver?.invalidate()
        
        UserDefaults.standard.removeObserver(self, forKeyPath: DefaultKeys.theme.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: DefaultKeys.showInvisibles.rawValue)
    }
    
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        
        switch keyPath {
        case DefaultKeys.theme.rawValue?:
            guard let name = change?[.newKey] as? String else { return }
            self.setTheme(name: name)
            
        case DefaultKeys.showInvisibles.rawValue?:
            self.showsInvisibles = change?[.newKey] as! Bool
            
        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        // set user defaults
        let defaults = UserDefaults.standard
        self.isStatusBarShown = defaults[.showStatusBar]
        self.showsInvisibles = defaults[.showInvisibles]
        self.showsLineNumber = defaults[.showLineNumbers]
        self.showsNavigationBar = defaults[.showNavigationBar]
        self.wrapsLines = defaults[.wrapLines]
        self.showsPageGuide = defaults[.showPageGuide]
        
        // set writing direction
        switch defaults[.writingDirection] {
        case .leftToRight:
            break
        case .rightToLeft:
            self.writingDirection = .rightToLeft
        case .vertical:
            self.verticalLayoutOrientation = true
        }
        
        // set theme
        let themeName = ThemeManager.shared.userDefaultSettingName(forDark: self.view.effectiveAppearance.isDark)
        self.setTheme(name: themeName)
        
        // observe theme change
        NotificationCenter.default.addObserver(self, selector: #selector(didUpdateTheme),
                                               name: didUpdateSettingNotification,
                                               object: ThemeManager.shared)
        UserDefaults.standard.addObserver(self, forKeyPath: DefaultKeys.theme.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: DefaultKeys.showInvisibles.rawValue, options: .new, context: nil)
        
        // observe appearance change for theme toggle
        self.appearanceObserver = self.view.observe(\.effectiveAppearance) { [unowned self] (_, _) in
            guard
                self.view.window != nil,
                let currentThemeName = self.theme?.name,
                let themeName = ThemeManager.shared.equivalentSettingName(to: currentThemeName, forDark: self.view.effectiveAppearance.isDark),
                currentThemeName != themeName
                else { return }
            
            self.setTheme(name: themeName)
        }
    }
    
    
    /// keys to be restored from the last session
    override class var restorableStateKeyPaths: [String] {
        
        return [#keyPath(isStatusBarShown),
                #keyPath(showsNavigationBar),
                #keyPath(showsLineNumber),
                #keyPath(showsPageGuide),
                #keyPath(showsInvisibles),
        ]
    }
    
    
    /// store UI state
    override func encodeRestorableState(with coder: NSCoder) {
        
        if let themeName = self.theme?.name {
            coder.encode(themeName, forKey: "theme")
        }
        
        super.encodeRestorableState(with: coder)
    }
    
    
    /// resume UI state
    override func restoreState(with coder: NSCoder) {
        
        super.restoreState(with: coder)
        
        if let themeName = coder.decodeObject(forKey: "theme") as? String {
            self.setTheme(name: themeName)
        }
    }
    
    
    /// deliver document to child view controllers
    override var representedObject: Any? {
        
        didSet {
            guard let document = representedObject as? Document else { return }
            
            (self.statusBarItem?.viewController as? StatusBarController)?.documentAnalyzer = document.analyzer
            
            document.textStorage.delegate = self
            document.syntaxParser.delegate = self
            
            let editorViewController = self.editorViewControllers.first!
            self.setup(editorViewController: editorViewController, baseViewController: nil)
            
            // start parcing syntax highlights and outline menu
            document.syntaxParser.invalidateOutline()
            self.invalidateSyntaxHighlight()
            
            // detect indent style
            if UserDefaults.standard[.detectsIndentStyle],
                let indentStyle = document.textStorage.string.detectedIndentStyle
            {
                self.isAutoTabExpandEnabled = {
                    switch indentStyle {
                    case .tab:
                        return false
                    case .space:
                        return true
                    }
                }()
            }
            
            // focus text view
            self.view.window?.makeFirstResponder(editorViewController.textView)
            
            // observe syntax change
            NotificationCenter.default.addObserver(self, selector: #selector(didChangeSyntaxStyle),
                                                   name: Document.didChangeSyntaxStyleNotification,
                                                   object: document)
        }
    }
    
    
    /// avoid showing draggable cursor
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        
        // -> must call super's delegate method anyway.
        super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        
        return .zero
    }
    
    
    /// apply current state to related toolbar items
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        
        guard let action = item.action else { return false }
        
        switch (action, item) {
        case (#selector(recolorAll), _):
            return self.syntaxParser?.canParse ?? false
            
        case (#selector(toggleLineWrap), let item as StatableToolbarItem):
            item.state = self.wrapsLines ? .on : .off
            
        case (#selector(toggleLineWrap), let item as StatableToolbarItem):
            item.state = self.wrapsLines ? .on : .off
            
        case (#selector(togglePageGuide), let item as StatableToolbarItem):
            item.state = self.showsPageGuide ? .on : .off
            
        case (#selector(toggleInvisibleChars), let item as StatableToolbarItem):
            item.state = self.showsInvisibles ? .on : .off
            
            // disable button if item cannot be enabled
            if self.canActivateShowInvisibles {
                item.toolTip = "Show or hide invisible characters in document".localized
            } else {
                item.toolTip = "To show invisible characters, set them in Preferences".localized
                return false
            }
            
        case (#selector(toggleAutoTabExpand), let item as StatableToolbarItem):
            item.state = self.isAutoTabExpandEnabled ? .on : .off
            
        case (#selector(changeWritingDirection), let item as SegmentedToolbarItem):
            let tag: Int = {
                switch (self.verticalLayoutOrientation, self.writingDirection) {
                case (true, _):
                    return 2
                case (false, .rightToLeft):
                    return 1
                default:
                    return 0
                }
            }()
            item.segmentedControl?.selectSegment(withTag: tag)
            
        case (#selector(changeOrientation), let item as SegmentedToolbarItem):
            let tag = self.verticalLayoutOrientation ? 1 : 0
            item.segmentedControl?.selectSegment(withTag: tag)
            
        default: break
        }
        
        return true
    }
    
    
    
    // MARK: Menu Item Validation
    
    /// validate menu items
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        
        guard let action = menuItem.action else { return false }
        
        switch action {
        case #selector(recolorAll):
            return self.syntaxParser?.canParse ?? false
            
        case #selector(toggleStatusBar):
            let title = self.isStatusBarShown ? "Hide Status Bar" : "Show Status Bar"
            menuItem.title = title.localized
            
        case #selector(toggleNavigationBar):
            let title = self.showsNavigationBar ? "Hide Navigation Bar" : "Show Navigation Bar"
            menuItem.title = title.localized
            
        case #selector(toggleLineNumber):
            let title = self.showsLineNumber ? "Hide Line Numbers" : "Show Line Numbers"
            menuItem.title = title.localized
            
        case #selector(toggleLineWrap):
            let title = self.wrapsLines ? "Unwrap Lines" : "Wrap Lines"
            menuItem.title = title.localized
            
        case #selector(togglePageGuide):
            let title = self.showsPageGuide ? "Hide Page Guide" : "Show Page Guide"
            menuItem.title = title.localized
            
        case #selector(toggleInvisibleChars):
            let title = self.showsInvisibles ? "Hide Invisible Characters" : "Show Invisible Characters"
            menuItem.title = title.localized
            // disable button if item cannot be enable
            if self.canActivateShowInvisibles {
                menuItem.toolTip = "Show or hide invisible characters in document".localized
            } else {
                menuItem.toolTip = "To show invisible characters, set them in Preferences".localized
                return false
            }
            
        case #selector(toggleAutoTabExpand):
            menuItem.state = self.isAutoTabExpandEnabled ? .on : .off
            
        case #selector(makeLayoutOrientationHorizontal):
            menuItem.state = self.verticalLayoutOrientation ? .off : .on
            
        case #selector(makeLayoutOrientationVertical):
            menuItem.state = self.verticalLayoutOrientation ? .on : .off
            
        case #selector(makeWritingDirectionLeftToRight):
            menuItem.state = (self.writingDirection == .leftToRight) ? .on : .off
            return !self.verticalLayoutOrientation
            
        case #selector(makeWritingDirectionRightToLeft):
            menuItem.state = (self.writingDirection == .rightToLeft) ? .on : .off
            return !self.verticalLayoutOrientation
            
        case #selector(toggleAntialias):
            menuItem.state = (self.focusedTextView?.usesAntialias ?? false) ? .on : .off
            
        case #selector(changeTabWidth):
            menuItem.state = (self.tabWidth == menuItem.tag) ? .on : .off
            
        case #selector(closeSplitTextView):
            return ((self.splitViewController?.splitViewItems.count ?? 0) > 1)
            
        case #selector(changeTheme):
            menuItem.state = (self.theme?.name == menuItem.title) ? .on : .off
            
        default: break
        }
        
        return true
    }
    
    
    
    // MARK: Delegate
    
    /// text did edit
    override func textStorageDidProcessEditing(_ notification: Notification) {
        
        // ignore if only attributes did change
        guard let textStorage = notification.object as? NSTextStorage,
            textStorage.editedMask.contains(.editedCharacters) else { return }
        
        // don't update when input text is not yet fixed.
        guard self.focusedTextView?.hasMarkedText() != true else { return }
        
        // update editor information
        // -> In case, if "Replace All" performed without moving caret.
        self.document?.analyzer.invalidateEditorInfo()
        
        // parse syntax
        if let syntaxParser = self.syntaxParser, syntaxParser.canParse {
            syntaxParser.invalidateOutline()
            
            // perform highlight in the next run loop to give layoutManager time to update temporary attribute
            let editedRange = textStorage.editedRange
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                if let progress = self.syntaxHighlightProgress {
                    // retry syntax highlight if the last highlightAll has not finished yet
                    progress.cancel()
                    self.syntaxHighlightProgress = self.syntaxParser?.highlightAll()
                } else {
                    _ = self.syntaxParser?.highlight(around: editedRange)
                }
            }
        }
        
        // update incompatible characters list
        self.document?.incompatibleCharacterScanner.invalidate()
    }
    
    
    /// update outline menu in navigation bar
    func syntaxParser(_ syntaxParser: SyntaxParser, didParseOutline outlineItems: [OutlineItem]) {
        
        for viewController in self.editorViewControllers {
            viewController.navigationBarController?.outlineProgress = nil
            viewController.navigationBarController?.outlineItems = outlineItems
            // -> The selection update will be done in the `otutlineItems`'s setter above, so you don't need invoke it (2008-05-16)
        }
    }
    
    
    func syntaxParser(_ syntaxParser: SyntaxParser, didStartParsingOutline progress: Progress) {
        
        for viewController in self.editorViewControllers {
            viewController.navigationBarController?.outlineProgress = progress
        }
    }
    
    
    
    // MARK: Notifications
    
    /// selection did change
    @objc private func textViewDidChangeSelection(_ notification: Notification?) {
        
        // update document information
        self.document?.analyzer.invalidateEditorInfo()
    }
    
    
    /// document updated syntax style
    @objc private func didChangeSyntaxStyle(_ notification: Notification?) {
        
        guard let syntaxParser = self.syntaxParser else { return assertionFailure() }
        
        syntaxParser.delegate = self
        
        for viewController in self.editorViewControllers {
            viewController.apply(style: syntaxParser.style)
            viewController.navigationBarController?.outlineItems = []
            viewController.navigationBarController?.outlineProgress = nil
        }
        
        syntaxParser.invalidateOutline()
        self.invalidateSyntaxHighlight()
    }
    
    
    /// theme did update
    @objc private func didUpdateTheme(_ notification: Notification?) {
        
        guard
            let oldName = notification?.userInfo?[Notification.UserInfoKey.old] as? String,
            oldName == self.theme?.name else { return }
        
        let newName = (notification?.userInfo?[Notification.UserInfoKey.new] as? String) ?? ThemeManager.shared.userDefaultSettingName(forDark: self.view.effectiveAppearance.isDark)
        
        self.setTheme(name: newName)
    }
    
    
    
    // MARK: Public Methods
    
    /// setup document
    var document: Document? {
        
        return self.representedObject as? Document
    }
    
    
    /// return textView focused on
    var focusedTextView: EditorTextView? {
        
        return self.splitViewController?.focusedSubviewController?.textView
    }
    
    
    /// coloring theme
    var theme: Theme? {
        
        return self.focusedTextView?.theme
    }
    
    
    /// body font
    var font: NSFont? {
        
        return self.focusedTextView?.font
    }
    
    
    /// Whether status bar is visible
    @objc var isStatusBarShown: Bool {
        
        get {
            return self.statusBarItem?.isCollapsed == false
        }
        
        set {
            assert(self.statusBarItem != nil)
            self.statusBarItem?.isCollapsed = !newValue
        }
    }
    
    
    /// visibility of navigation bars
    @objc var showsNavigationBar = false {
        
        didSet {
            for viewController in self.editorViewControllers {
                viewController.showsNavigationBar = showsNavigationBar
            }
        }
    }
    
    
    /// visibility of line numbers view
    @objc var showsLineNumber = false {
        
        didSet {
            for viewController in self.editorViewControllers {
                viewController.showsLineNumber = showsLineNumber
            }
        }
    }
    
    
    /// if lines soft-wrap at window edge
    var wrapsLines = false {
        
        didSet {
            for viewController in self.editorViewControllers {
                viewController.textView?.wrapsLines = wrapsLines
            }
        }
    }
    
    
    /// visibility of page guide lines in text view
    @objc var showsPageGuide = false {
        
        didSet {
            for viewController in self.editorViewControllers {
                viewController.textView?.showsPageGuide = showsPageGuide
            }
        }
    }
    
    
    /// visibility of invisible characters
    @objc var showsInvisibles = false {
        
        didSet {
            for viewController in self.editorViewControllers {
                viewController.textView?.showsInvisibles = showsInvisibles
            }
        }
    }
    
    
    /// if text orientation is vertical
    @objc var verticalLayoutOrientation: Bool {
        
        get {
            guard let textView = self.focusedTextView else {
                return UserDefaults.standard[.writingDirection] == .vertical
            }
            
            return textView.layoutOrientation == .vertical
        }
        
        set {
            self.document?.isVerticalText = newValue
            
            let orientation: NSLayoutManager.TextLayoutOrientation = newValue ? .vertical : .horizontal
            
            for viewController in self.editorViewControllers {
                viewController.textView?.setLayoutOrientation(orientation)
            }
        }
    }
    
    
    var writingDirection: NSWritingDirection {
        
        get {
            return self.focusedTextView?.baseWritingDirection ?? .leftToRight
        }
        
        set {
            for viewController in self.editorViewControllers {
                viewController.textView?.baseWritingDirection = newValue
            }
        }
    }
    
    
    /// textView's tab width
    var tabWidth: Int {
        
        get {
            return self.focusedTextView?.tabWidth ?? 0
        }
        
        set {
            for viewController in self.editorViewControllers {
                viewController.textView?.tabWidth = newValue
            }
        }
    }
    
    
    /// whether replace tab with spaces
    var isAutoTabExpandEnabled: Bool {
        
        get {
            return self.focusedTextView?.isAutomaticTabExpansionEnabled ?? UserDefaults.standard[.autoExpandTab]
        }
        
        set {
            for viewController in self.editorViewControllers {
                viewController.textView?.isAutomaticTabExpansionEnabled = newValue
            }
        }
    }
    
    
    /// apply text styles from text view
    func invalidateStyleInTextStorage() {
        
        self.focusedTextView?.invalidateStyle()
    }
    
    
    
    // MARK: Action Messages
    
    /// toggle visibility of status bar with fancy animation
    @IBAction func toggleStatusBar(_ sender: Any?) {
        
        NSAnimationContext.current.withAnimation {
            self.isStatusBarShown.toggle()
        }
        
        UserDefaults.standard[.showStatusBar] = self.isStatusBarShown
    }
    
    
    /// toggle visibility of navigation bar with fancy animation
    @IBAction func toggleNavigationBar(_ sender: Any?) {
        
        NSAnimationContext.current.withAnimation {
            self.showsNavigationBar.toggle()
        }
        
        UserDefaults.standard[.showNavigationBar] = self.showsNavigationBar
    }
    
    
    /// toggle visibility of line number view
    @IBAction func toggleLineNumber(_ sender: Any?) {
        
        self.showsLineNumber.toggle()
    }
    
    
    /// toggle if lines wrap at window edge
    @IBAction func toggleLineWrap(_ sender: Any?) {
        
        self.wrapsLines.toggle()
    }
    
    
    /// change writing direction from segmented control button
    @IBAction func changeWritingDirection(_ sender: NSSegmentedControl) {
        
        switch sender.selectedSegment {
        case 0:
            self.makeLayoutOrientationHorizontal(nil)
            self.makeWritingDirectionLeftToRight(nil)
        case 1:
            self.makeLayoutOrientationHorizontal(nil)
            self.makeWritingDirectionRightToLeft(nil)
        case 2:
            self.makeWritingDirectionLeftToRight(nil)
            self.makeLayoutOrientationVertical(nil)
        default:
            assertionFailure("Segmented writing direction button must have 3 segments only.")
        }
    }
    
    
    /// change layout orientation from segmented control button
    @IBAction func changeOrientation(_ sender: NSSegmentedControl) {
        
        switch sender.selectedSegment {
        case 0:
            self.makeLayoutOrientationHorizontal(nil)
        case 1:
            self.makeLayoutOrientationVertical(nil)
        default:
            assertionFailure("Segmented layout orientation button must have 2 segments only.")
        }
    }
    
    
    /// make text layout orientation horizontal
    @IBAction func makeLayoutOrientationHorizontal(_ sender: Any?) {
        
        self.verticalLayoutOrientation = false
    }
    
    
    /// make text layout orientation vertical
    @IBAction func makeLayoutOrientationVertical(_ sender: Any?) {
        
        self.verticalLayoutOrientation = true
    }
    
    
    /// make entire writing direction LTR
    @IBAction func makeWritingDirectionLeftToRight(_ sender: Any?) {
        
        self.writingDirection = .leftToRight
    }
    
    
    /// make entire writing direction RTL
    @IBAction func makeWritingDirectionRightToLeft(_ sender: Any?) {
        
        self.writingDirection = .rightToLeft
    }
    
    
    /// toggle if antialias text in text view
    @IBAction func toggleAntialias(_ sender: Any?) {
        
        guard let usesAntialias = self.focusedTextView?.usesAntialias else { return assertionFailure() }
        
        for viewController in self.editorViewControllers {
            viewController.textView?.usesAntialias = !usesAntialias
        }
    }
    
    
    /// toggle visibility of invisible characters in text view
    @IBAction func toggleInvisibleChars(_ sender: Any?) {
        
        self.showsInvisibles.toggle()
    }
    
    
    /// toggle visibility of page guide line in text view
    @IBAction func togglePageGuide(_ sender: Any?) {
        
        self.showsPageGuide.toggle()
    }
    
    
    /// toggle if text view expands tab input
    @IBAction func toggleAutoTabExpand(_ sender: Any?) {
        
        self.isAutoTabExpandEnabled.toggle()
    }
    
    
    /// change tab width from the main menu
    @IBAction func changeTabWidth(_ sender: NSMenuItem) {
        
        self.tabWidth = sender.tag
    }
    
    
    /// change tab width to desired number through a sheet
    @IBAction func customizeTabWidth(_ sender: Any?) {
        
        let viewController = CustomTabWidthViewController.instantiate(storyboard: "CustomTabWidthView")
        viewController.defaultWidth = self.tabWidth
        viewController.completionHandler = { [weak self] (tabWidth) in
            self?.tabWidth = tabWidth
        }
        
        self.presentAsSheet(viewController)
    }
    
    
    /// set new theme from menu item
    @IBAction func changeTheme(_ sender: AnyObject?) {
        
        guard let name = sender?.title else { return assertionFailure() }
        
        self.setTheme(name: name)
    }
    
    
    /// re-color whole document
    @IBAction func recolorAll(_ sender: Any?) {
        
        self.invalidateSyntaxHighlight()
    }
    
    
    /// split editor view
    @IBAction func openSplitTextView(_ sender: Any?) {
        
        guard (self.splitViewController?.splitViewItems.count ?? 0) < maximumNumberOfSplitEditors else {
            NSSound.beep()
            return
        }
        
        guard let currentEditorViewController = self.findTargetEditorViewController(for: sender) else { return }
        
        // end current editing
        NSTextInputContext.current?.discardMarkedText()
        
        let newEditorViewController = EditorViewController.instantiate(storyboard: "EditorView")
        self.splitViewController?.addSubview(for: newEditorViewController, relativeTo: currentEditorViewController)
        self.setup(editorViewController: newEditorViewController, baseViewController: currentEditorViewController)
        
        newEditorViewController.navigationBarController?.outlineItems = self.syntaxParser?.outlineItems ?? []
        self.invalidateSyntaxHighlight()
        
        // adjust visible areas
        newEditorViewController.textView?.selectedRange = currentEditorViewController.textView!.selectedRange
        currentEditorViewController.textView?.centerSelectionInVisibleArea(self)
        newEditorViewController.textView?.centerSelectionInVisibleArea(self)
        
        // move focus to the new editor
        self.view.window?.makeFirstResponder(newEditorViewController.textView)
    }
    
    
    /// close one of split views
    @IBAction func closeSplitTextView(_ sender: Any?) {
        
        guard
            let splitViewController = self.splitViewController,
            let currentEditorViewController = self.findTargetEditorViewController(for: sender)
            else { return }
        
        // end current editing
        NSTextInputContext.current?.discardMarkedText()
        
        // move focus to the next text view if the view to close has a focus
        if splitViewController.focusedSubviewController == currentEditorViewController {
            let childViewControllers = self.editorViewControllers
            let deleteIndex = childViewControllers.index(of: currentEditorViewController) ?? 0
            let newFocusEditorViewController = childViewControllers[safe: deleteIndex + 1] ?? childViewControllers.first!
            
            self.view.window?.makeFirstResponder(newFocusEditorViewController.textView)
        }
        
        // close
        if let splitViewItem = splitViewController.splitViewItem(for: currentEditorViewController) {
            splitViewController.removeSplitViewItem(splitViewItem)
        
            if let textView = currentEditorViewController.textView {
                NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: textView)
            }
        }
    }
    
    
    
    // MARK: Private Methods
    
    /// whether at least one of invisible characters is enabled in the preferences currently
    private var canActivateShowInvisibles: Bool {
        
        let defaults = UserDefaults.standard
        return (defaults[.showInvisibleSpace] ||
            defaults[.showInvisibleTab] ||
            defaults[.showInvisibleNewLine] ||
            defaults[.showInvisibleFullwidthSpace] ||
            defaults[.showOtherInvisibleChars])
    }
    
    
    /// re-highlight whole content
    private func invalidateSyntaxHighlight() {
        
        self.syntaxHighlightProgress = self.syntaxParser?.highlightAll()
    }
    
    
    /// create and set-up new (split) editor view
    private func setup(editorViewController: EditorViewController, baseViewController: EditorViewController?) {
        
        editorViewController.setTextStorage(self.textStorage!)
        
        editorViewController.textView?.wrapsLines = self.wrapsLines
        editorViewController.textView?.showsInvisibles = self.showsInvisibles
        editorViewController.textView?.setLayoutOrientation(self.verticalLayoutOrientation ? .vertical : .horizontal)
        editorViewController.textView?.showsPageGuide = self.showsPageGuide
        editorViewController.showsNavigationBar = self.showsNavigationBar
        editorViewController.showsLineNumber = self.showsLineNumber  // need to be set after setting text orientation
        
        if let syntaxParser = self.syntaxParser {
            editorViewController.apply(style: syntaxParser.style)
        }
        
        // copy textView states
        if let baseTextView = baseViewController?.textView, let textView = editorViewController.textView {
            textView.font = baseTextView.font
            textView.theme = baseTextView.theme
            textView.tabWidth = baseTextView.tabWidth
            textView.baseWritingDirection = baseTextView.baseWritingDirection
            textView.isAutomaticTabExpansionEnabled = baseTextView.isAutomaticTabExpansionEnabled
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(textViewDidChangeSelection),
                                               name: NSTextView.didChangeSelectionNotification,
                                               object: editorViewController.textView)
    }
    
    
    /// split view controller
    private var splitViewController: SplitViewController? {
        
        return self.splitViewItem?.viewController as? SplitViewController
    }
    
    
    /// text storage
    private var textStorage: NSTextStorage? {
        
        return self.document?.textStorage
    }
    
    
    /// document's syntax parser
    private var syntaxParser: SyntaxParser? {
        
        return self.document?.syntaxParser
    }
    
    
    /// child editor view controllers
    private var editorViewControllers: [EditorViewController] {
        
        return self.splitViewController?.children as? [EditorViewController] ?? []
    }
    
    
    /// apply theme
    private func setTheme(name: String) {
        
        assert(Thread.isMainThread)
        
        guard
            let theme = ThemeManager.shared.setting(name: name),
            theme != self.theme
            else { return }
        
        for viewController in self.editorViewControllers {
            viewController.textView?.theme = theme
        }
        
        self.invalidateSyntaxHighlight()
        self.invalidateRestorableState()
    }
    
    
    /// find target EditorViewController to manage split views for action sender
    private func findTargetEditorViewController(for sender: Any?) -> EditorViewController? {
        
        guard
            let view = (sender is NSMenuItem) ? (self.view.window?.firstResponder as? NSView) : sender as? NSView,
            let editorView = sequence(first: view, next: { $0.superview }).first(where: { $0.identifier == NSUserInterfaceItemIdentifier("EditorView") })
            else { return nil }
        
        return self.splitViewController?.viewController(for: editorView)
    }
    
}



// MARK: Protocol

extension DocumentViewController: TextFinderClientProvider {
    
    /// tell text finder in which text view should it find text
    func textFinderClient() -> NSTextView? {
        
        return self.focusedTextView
    }
}
