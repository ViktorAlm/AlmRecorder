import Foundation
import GRDB

/// Live review counts, pushed by the DATABASE itself — no polling.
///
/// GRDB's ValueObservation re-evaluates the tracked query after every committed write that
/// touches its region (the utterances table), so the sidebar badge and the review inbox react
/// to EVERY writer the moment it commits: Keep/Fix/Hide in the inbox, Mark-as-trash on any
/// surface, the exemplar sweep flagging lookalikes, and Gemma verdicts landing from the
/// background queue. This replaces the original 30-second poll, which is why the badge used
/// to lag user actions.
final class ReviewInboxModel: ObservableObject {

    static let shared = ReviewInboxModel()

    struct Counts: Equatable {
        var pending = 0
        var autoHidden = 0
        var autoCorrected = 0
    }

    @Published private(set) var counts = Counts()

    private var cancellable: AnyDatabaseCancellable?
    private let logger = VoxtralLogger.shared

    private init() {
        let observation = ValueObservation
            .tracking { db -> Counts in
                func count(_ status: UtteranceReviewStatus) throws -> Int {
                    try Int.fetchOne(db,
                                     sql: "SELECT COUNT(*) FROM utterances WHERE review_status = ?",
                                     arguments: [status.rawValue]) ?? 0
                }
                return Counts(pending: try count(.pendingReview),
                              autoHidden: try count(.autoHidden),
                              autoCorrected: try count(.autoCorrected))
            }
            .removeDuplicates()

        cancellable = observation.start(
            in: GRDBDatabaseManager.shared.getDatabaseQueue(),
            scheduling: .async(onQueue: .main),
            onError: { [logger] error in
                logger.error("[ReviewInboxModel] Count observation failed: \(error.localizedDescription)")
            },
            onChange: { [weak self] counts in
                self?.counts = counts
            }
        )
    }
}
