//
//  ChatCommandContext.swift
//  AFM Code
//
//  Focused values that share window state with the keyboard commands in
//  `SessionCommands` — the same three-struct split Perspective
//  Intelligence uses for its ConversationTabCommands:
//
//  - `SessionSceneCommands`: everything the window knows — the ordered
//    session list (recents, previous/next), the current selection, and
//    whether the selected session is mid-turn. Published by RootView.
//  - `SessionDetailCommands`: what the visible chat offers — copy and
//    regenerate, the model picker, the composer, and composer focus.
//    Published by ChatView, so it exists only while a session is shown.
//  - `SessionListCommands`: what the sidebar offers — deletion of the
//    selected session, with its confirmation owned by the sidebar.
//
//  Focused values are compared on every render. Equality covers only the
//  data that changes the menus; the closures read live state when
//  invoked. Without it, each render would publish a "new" value and
//  re-render the scene forever.
//

import SwiftUI

/// Actions and the recent-session list a window offers to keyboard commands.
struct SessionSceneCommands: Equatable {
    struct RecentSession: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    /// Most recent first, matching the sidebar order; at most ten for
    /// ⌘1–⌘0.
    let recentSessions: [RecentSession]
    let selectedSessionID: UUID?
    /// The sessions just above and below the selected one in the ordered
    /// list, for ⌥⌘↑ / ⌥⌘↓.
    let previousSessionID: UUID?
    let nextSessionID: UUID?
    /// True while the selected session's engine is mid-turn.
    let isResponding: Bool
    /// True while the detail pane shows a project (⌘N's only valid home).
    let canCreateSession: Bool
    let selectSession: (UUID) -> Void
    let stopResponse: () -> Void
    let createSession: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recentSessions == rhs.recentSessions
            && lhs.selectedSessionID == rhs.selectedSessionID
            && lhs.previousSessionID == rhs.previousSessionID
            && lhs.nextSessionID == rhs.nextSessionID
            && lhs.isResponding == rhs.isResponding
            && lhs.canCreateSession == rhs.canCreateSession
    }
}

/// Actions the visible session offers to keyboard commands.
struct SessionDetailCommands: Equatable {
    let canRegenerate: Bool
    let canCopyLastResponse: Bool
    let canCopyTranscript: Bool
    let isComposerFocused: Bool
    let regenerateLastResponse: () -> Void
    let copyLastResponse: () -> Void
    let copyTranscript: () -> Void
    let showModelPicker: () -> Void
    let focusComposer: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canRegenerate == rhs.canRegenerate
            && lhs.canCopyLastResponse == rhs.canCopyLastResponse
            && lhs.canCopyTranscript == rhs.canCopyTranscript
            && lhs.isComposerFocused == rhs.isComposerFocused
    }
}

/// The sidebar owns session deletion and its confirmation.
struct SessionListCommands: Equatable {
    let canDeleteSelectedSession: Bool
    let deleteSelectedSession: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canDeleteSelectedSession == rhs.canDeleteSelectedSession
    }
}

struct SessionSceneCommandsFocusKey: FocusedValueKey {
    typealias Value = SessionSceneCommands
}

struct SessionDetailCommandsFocusKey: FocusedValueKey {
    typealias Value = SessionDetailCommands
}

struct SessionListCommandsFocusKey: FocusedValueKey {
    typealias Value = SessionListCommands
}

extension FocusedValues {
    var afmSceneCommands: SessionSceneCommands? {
        get { self[SessionSceneCommandsFocusKey.self] }
        set { self[SessionSceneCommandsFocusKey.self] = newValue }
    }

    var afmDetailCommands: SessionDetailCommands? {
        get { self[SessionDetailCommandsFocusKey.self] }
        set { self[SessionDetailCommandsFocusKey.self] = newValue }
    }

    var afmListCommands: SessionListCommands? {
        get { self[SessionListCommandsFocusKey.self] }
        set { self[SessionListCommandsFocusKey.self] = newValue }
    }
}
