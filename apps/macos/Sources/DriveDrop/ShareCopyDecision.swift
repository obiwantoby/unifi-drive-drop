import Foundation

// What a click on a link row means.
//
// Deliberately pure: no clipboard, no network, no `Date()` read — `now` is a parameter so the
// expiry boundary can be tested exactly. Clicking must never round-trip to the console; the
// row is what the user saw, and the row is what they get.

enum RowTap: Equatable {
    /// Put this exact URL on the clipboard.
    case copy(URL)
    /// Nothing to copy. Show the row's own actions rather than refusing with silence.
    case offer(RowUnavailable)
}

enum RowUnavailable: Equatable, Hashable {
    case demo          // mock data — the URL is fiction, copying it is a lie
    case queued
    case uploading
    case finalizing    // bytes all sent, console has not made the object visible
    case sharing       // link not created yet
    case failed(String)
    case expired       // a link exists; this URL is already dead
    case noLink        // file on the Drive, no share link

    var why: String {
        switch self {
        case .demo:      return "Demo data — these links are not real"
        case .queued:    return "Waiting to upload"
        case .uploading: return "Still uploading"
        case .finalizing: return "Finalizing on the console…"
        case .sharing:   return "Creating the link…"
        case .failed(let m): return m
        case .expired:   return "This link has expired"
        case .noLink:    return "Not shared yet"
        }
    }
}

enum RowAction: String, Equatable {
    case reShare, retry, dismiss, openWindow

    var title: String {
        switch self {
        case .reShare:    return "Create new link"
        case .retry:      return "Retry upload"
        case .dismiss:    return "Dismiss"
        case .openWindow: return "Open window"
        }
    }
}

enum RowTapPolicy {
    /// `expiresAt == nil` means **never**, not "unknown" — the console sends `""` for a link
    /// with no expiry, and treating that as epoch 0 would mark every permanent link expired.
    /// The boundary is inclusive: at the instant of expiry the URL has stopped working.
    static func isExpired(_ item: ShareItem, now: Date) -> Bool {
        guard let e = item.expiresAt else { return false }
        return e <= now
    }

    static func decide(_ item: ShareItem, now: Date, demo: Bool) -> RowTap {
        // Checked before anything else: a demo row carries a plausible-looking
        // https://drop.ui.com/… URL that belongs to nobody.
        if demo { return .offer(.demo) }

        switch item.phase {
        case .failed(let msg): return .offer(.failed(msg))
        case .queued:          return .offer(.queued)
        case .uploading:       return .offer(.uploading)
        case .finalizing:      return .offer(.finalizing)
        case .sharing:         return .offer(.sharing)
        case .ready:           break
        }

        if isExpired(item, now: now) { return .offer(.expired) }

        // A share URL is the only thing worth copying. `directURL` is console-authenticated
        // and useless to the person you are sending it to; `localPath` is worse than useless.
        guard let url = item.shareURL,
              url.scheme == "https",
              !url.absoluteString.isEmpty
        else { return .offer(.noLink) }

        return .copy(url)
    }

    /// Which actions to expose when there is nothing to copy.
    ///
    /// `reShare` appears only where rotating the token cannot destroy something that still
    /// works: an expired URL is already failing, and a row with no link has no URL at all.
    /// It never appears for a live link — recreating that would kill a URL the user may
    /// already have sent to someone.
    static func actions(for u: RowUnavailable) -> [RowAction] {
        switch u {
        case .demo:                      return [.openWindow]
        case .queued, .uploading:        return [.openWindow]
        case .finalizing, .sharing:      return [.openWindow]
        case .failed:                    return [.retry, .dismiss]
        case .expired:                   return [.reShare, .dismiss]
        case .noLink:                    return [.reShare]
        }
    }
}
