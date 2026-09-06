import Foundation
import Accelerate
import DBSCAN

/// Service for unifying speaker identities across multiple audio chunks
class SpeakerUnificationService {
    
    // MARK: - Types
    
    struct ChunkSpeaker {
        let chunkId: Int
        let localSpeakerId: String
        let embedding: [Float]
        let startTime: TimeInterval  // Global time in recording
        let endTime: TimeInterval
        let confidence: Float
    }
    
    struct UnificationResult {
        let globalSpeakerMap: [String: String]  // "chunk_local" -> "global_id"
        let speakerProfiles: [SpeakerProfile]
        let similarityMatrix: [[Float]]?  // For debugging
    }
    
    struct SpeakerProfile {
        let globalId: String
        let averageEmbedding: [Float]
        let sampleCount: Int
        let totalDuration: TimeInterval
        let confidence: Float
    }
    
    // MARK: - Properties
    
    private let logger = VoxtralLogger.shared
    private let similarityThreshold: Float
    private let embeddingService: any SpeakerEmbeddingService
    
    // MARK: - Initialization
    
    init(
        similarityThreshold: Float = 0.85,
        embeddingService: any SpeakerEmbeddingService
    ) {
        self.similarityThreshold = similarityThreshold
        self.embeddingService = embeddingService
    }
    
    // MARK: - Public Methods
    
    /// Unify speakers across multiple chunks based on embedding similarity
    /// - Parameters:
    ///   - chunkSpeakers: Array of speakers from different chunks with embeddings
    ///   - targetSpeakerCount: Optional target number of speakers to cluster into
    /// - Returns: Mapping from local speaker IDs to global IDs
    func unifySpeakers(
        from chunkSpeakers: [ChunkSpeaker],
        targetSpeakerCount: Int? = nil
    ) -> UnificationResult {
        logger.info("[SpeakerUnification] Unifying \(chunkSpeakers.count) speakers across chunks")
        
        guard !chunkSpeakers.isEmpty else {
            return UnificationResult(
                globalSpeakerMap: [:],
                speakerProfiles: [],
                similarityMatrix: nil
            )
        }
        
        // Build similarity matrix
        let similarityMatrix = buildSimilarityMatrix(speakers: chunkSpeakers)
        
        // Perform clustering
        let clusters: [[Int]]
        if let targetCount = targetSpeakerCount, targetCount > 0 {
            // Force clustering to specific number of speakers
            clusters = performHierarchicalClusteringWithTarget(
                similarityMatrix: similarityMatrix,
                targetClusters: targetCount
            )
        } else {
            // Use adaptive clustering with automatic threshold selection
            clusters = performAdaptiveClustering(
                similarityMatrix: similarityMatrix,
                chunkSpeakers: chunkSpeakers
            )
        }
        
        // Assign global speaker IDs
        let globalMap = assignGlobalSpeakerIds(
            clusters: clusters,
            chunkSpeakers: chunkSpeakers
        )
        
        // Create speaker profiles
        let profiles = createSpeakerProfiles(
            clusters: clusters,
            chunkSpeakers: chunkSpeakers,
            globalMap: globalMap
        )
        
        logger.info("[SpeakerUnification] Unified into \(clusters.count) unique speakers")
        
        return UnificationResult(
            globalSpeakerMap: globalMap,
            speakerProfiles: profiles,
            similarityMatrix: similarityMatrix
        )
    }
    
    /// Find best matching speaker from a set of profiles
    /// - Parameters:
    ///   - embedding: Speaker embedding to match
    ///   - profiles: Known speaker profiles
    ///   - threshold: Minimum similarity threshold
    /// - Returns: Best matching profile or nil
    func findBestMatch(
        embedding: [Float],
        among profiles: [SpeakerProfile],
        threshold: Float? = nil
    ) -> (profile: SpeakerProfile, similarity: Float)? {
        
        let minThreshold = threshold ?? similarityThreshold
        var bestMatch: (SpeakerProfile, Float)?
        
        for profile in profiles {
            let similarity = embeddingService.similarity(embedding, profile.averageEmbedding)
            
            if similarity >= minThreshold {
                if bestMatch == nil || similarity > bestMatch!.1 {
                    bestMatch = (profile, similarity)
                }
            }
        }
        
        return bestMatch
    }
    
    // MARK: - Private Methods
    
    /// Perform adaptive clustering using DBSCAN
    private func performAdaptiveClustering(
        similarityMatrix: [[Float]],
        chunkSpeakers: [ChunkSpeaker]
    ) -> [[Int]] {
        guard !chunkSpeakers.isEmpty else { return [] }
        
        // Convert embeddings to array format for DBSCAN
        // We'll use the embeddings directly as the input data
        let embeddings = chunkSpeakers.map { $0.embedding }
        
        // Custom distance function using cosine distance (1 - similarity)
        let distanceFunction: ([Float], [Float]) -> Double = { embedding1, embedding2 in
            // Calculate cosine similarity and convert to distance
            let similarity = self.embeddingService.similarity(embedding1, embedding2)
            return Double(1.0 - similarity)
        }
        
        // Create DBSCAN instance with embeddings
        let dbscan = DBSCAN(embeddings)
        
        // Try different epsilon values (maximum distance between points in same cluster)
        // For cosine distance with speaker embeddings, use STRICTER epsilon for better separation
        // Lower epsilon = more strict clustering (speakers must be more similar to group)
        let epsilons: [Double] = [0.05, 0.08, 0.1, 0.13, 0.16, 0.2, 0.25, 0.3]
        var bestIndices: [[Int]] = []
        var bestScore: Float = -Float.infinity
        var bestEpsilon: Double = 0.15  // Prefer separation — users can merge later
        
        logger.info("[SpeakerUnification] DBSCAN clustering \(chunkSpeakers.count) segments")
        
        // Log similarity statistics for debugging
        var allSimilarities: [Float] = []
        for i in 0..<chunkSpeakers.count {
            for j in (i+1)..<chunkSpeakers.count {
                let similarity = embeddingService.similarity(chunkSpeakers[i].embedding, chunkSpeakers[j].embedding)
                allSimilarities.append(similarity)
            }
        }
        if !allSimilarities.isEmpty {
            let avgSim = allSimilarities.reduce(0, +) / Float(allSimilarities.count)
            let minSim = allSimilarities.min() ?? 0
            let maxSim = allSimilarities.max() ?? 1
            logger.info("[SpeakerUnification] Embedding similarities: avg=\(String(format: "%.3f", avgSim)), min=\(String(format: "%.3f", minSim)), max=\(String(format: "%.3f", maxSim))")
        }
        
        for epsilon in epsilons {
            // DBSCAN parameters:
            // - epsilon: maximum distance for points to be in same cluster
            // - minimumNumberOfPoints: minimum points to form a cluster
            // Use smaller divisor for minPoints to allow smaller clusters (better for detecting multiple speakers)
            let minPoints = max(2, min(8, chunkSpeakers.count / 25))  // Lower minPoints for finer clustering
            
            // Run DBSCAN clustering
            let (clusters, outliers) = dbscan.callAsFunction(
                epsilon: epsilon,
                minimumNumberOfPoints: minPoints,
                distanceFunction: distanceFunction
            )
            
            // Convert clusters back to indices
            var clusterIndices: [[Int]] = []
            
            for cluster in clusters {
                var indices: [Int] = []
                for embedding in cluster {
                    // Find the index of this embedding in the original array
                    if let idx = embeddings.firstIndex(where: { $0 == embedding }) {
                        indices.append(idx)
                    }
                }
                if !indices.isEmpty {
                    clusterIndices.append(indices)
                }
            }
            
            // Add outliers as single-point clusters if they exist
            for outlier in outliers {
                if let idx = embeddings.firstIndex(where: { $0 == outlier }) {
                    clusterIndices.append([idx])
                }
            }
            
            // Evaluate clustering quality
            if !clusterIndices.isEmpty {
                let uniqueLocalIds = Set(chunkSpeakers.map { $0.localSpeakerId })
                let score = evaluateDBSCANClustering(
                    clusters: clusterIndices,
                    similarityMatrix: similarityMatrix,
                    noiseCount: outliers.count,
                    uniqueLocalSpeakerCount: uniqueLocalIds.count
                )
                
                logger.info("[SpeakerUnification] DBSCAN eps=\(epsilon): \(clusters.count) clusters, \(outliers.count) outliers, score: \(score)")
                
                if score > bestScore {
                    bestScore = score
                bestIndices = clusterIndices
                    bestEpsilon = epsilon
                }
            }
        }
        
        if !bestIndices.isEmpty {
            logger.info("[SpeakerUnification] DBSCAN selected epsilon=\(bestEpsilon) with \(bestIndices.count) speakers (score: \(bestScore))")
            return bestIndices
        }
        
        // Fallback to hierarchical clustering if DBSCAN fails
        logger.warning("[SpeakerUnification] DBSCAN failed, falling back to hierarchical clustering")
        return performHierarchicalClustering(
            similarityMatrix: similarityMatrix,
            threshold: similarityThreshold
        )
    }
    
    /// Evaluate DBSCAN clustering quality
    private func evaluateDBSCANClustering(
        clusters: [[Int]],
        similarityMatrix: [[Float]],
        noiseCount: Int,
        uniqueLocalSpeakerCount: Int = 2
    ) -> Float {
        guard !clusters.isEmpty else { return 0 }

        // Calculate average intra-cluster similarity
        var intraClusterSim: Float = 0
        var intraPairs = 0

        for cluster in clusters {
            if cluster.count < 2 { continue }

            for i in 0..<cluster.count {
                for j in (i+1)..<cluster.count {
                    intraClusterSim += similarityMatrix[cluster[i]][cluster[j]]
                    intraPairs += 1
                }
            }
        }

        let avgIntraSim = intraPairs > 0 ? intraClusterSim / Float(intraPairs) : 0

        // Penalize too few clusters — prefer over-segmentation (users can merge later)
        let clusterPenalty: Float
        switch clusters.count {
        case 1:
            // Only penalize if diarization detected multiple unique speakers.
            // If input had only 1 unique local speaker, a single cluster is expected.
            clusterPenalty = uniqueLocalSpeakerCount <= 1 ? 1.0 : 0.15
        case 2...5:
            clusterPenalty = 1.0  // Optimal range for conversations
        case 6...8:
            clusterPenalty = 0.9  // Acceptable — don't penalize many speakers harshly
        case 9...15:
            clusterPenalty = 0.7  // Still fine — user can merge later
        default:
            clusterPenalty = 0.4  // Very many speakers, slight penalty
        }
        
        // Penalize high noise ratio
        let totalPoints = clusters.reduce(0) { $0 + $1.count } + noiseCount
        let noisePenalty = 1.0 - Float(noiseCount) / Float(totalPoints)
        
        return avgIntraSim * clusterPenalty * noisePenalty
    }
    
    /// Evaluate clustering quality using average intra-cluster similarity
    private func evaluateClustering(
        clusters: [[Int]],
        similarityMatrix: [[Float]]
    ) -> Float {
        guard !clusters.isEmpty else { return 0 }
        
        var totalScore: Float = 0
        var totalPairs = 0
        
        for cluster in clusters {
            if cluster.count < 2 { continue }
            
            // Calculate average similarity within cluster
            var clusterSim: Float = 0
            var pairs = 0
            
            for i in 0..<cluster.count {
                for j in (i+1)..<cluster.count {
                    clusterSim += similarityMatrix[cluster[i]][cluster[j]]
                    pairs += 1
                }
            }
            
            if pairs > 0 {
                totalScore += clusterSim / Float(pairs)
                totalPairs += 1
            }
        }
        
        // Penalize having too many or too few clusters
        let clusterPenalty: Float
        if clusters.count == 1 {
            clusterPenalty = 0.5  // Too few clusters
        } else if clusters.count > 10 {
            clusterPenalty = Float(10) / Float(clusters.count)  // Too many clusters
        } else {
            clusterPenalty = 1.0
        }
        
        return totalPairs > 0 ? (totalScore / Float(totalPairs)) * clusterPenalty : 0
    }
    
    /// Perform hierarchical clustering with a target number of clusters
    private func performHierarchicalClusteringWithTarget(
        similarityMatrix: [[Float]],
        targetClusters: Int
    ) -> [[Int]] {
        let n = similarityMatrix.count
        guard n > 0 && targetClusters > 0 else { return [] }
        
        // Start with each speaker in their own cluster
        var clusters = (0..<n).map { [$0] }
        var activeClusters = Set(0..<n)
        
        // Keep merging until we reach target number
        while activeClusters.count > targetClusters {
            // Find closest pair of clusters
            var maxSimilarity: Float = -1
            var mergeI = -1
            var mergeJ = -1
            
            for i in activeClusters {
                for j in activeClusters where j > i {
                    // Average linkage
                    let avgSim = averageSimilarity(
                        cluster1: clusters[i],
                        cluster2: clusters[j],
                        similarityMatrix: similarityMatrix
                    )
                    
                    if avgSim > maxSimilarity {
                        maxSimilarity = avgSim
                        mergeI = i
                        mergeJ = j
                    }
                }
            }
            
            // Merge the closest clusters
            if mergeI >= 0 && mergeJ >= 0 {
                clusters[mergeI].append(contentsOf: clusters[mergeJ])
                activeClusters.remove(mergeJ)
            } else {
                break
            }
        }
        
        // Return only active clusters
        return activeClusters.sorted().map { clusters[$0] }
    }
    
    /// Calculate average similarity between two clusters
    private func averageSimilarity(
        cluster1: [Int],
        cluster2: [Int],
        similarityMatrix: [[Float]]
    ) -> Float {
        var total: Float = 0
        var count = 0
        
        for i in cluster1 {
            for j in cluster2 {
                total += similarityMatrix[i][j]
                count += 1
            }
        }
        
        return count > 0 ? total / Float(count) : 0
    }
    
    private func buildSimilarityMatrix(speakers: [ChunkSpeaker]) -> [[Float]] {
        let count = speakers.count
        var matrix = Array(repeating: Array(repeating: Float(0), count: count), count: count)
        
        for i in 0..<count {
            matrix[i][i] = 1.0  // Self-similarity
            
            for j in (i+1)..<count {
                let similarity = embeddingService.similarity(
                    speakers[i].embedding,
                    speakers[j].embedding
                )
                matrix[i][j] = similarity
                matrix[j][i] = similarity  // Symmetric
            }
        }
        
        return matrix
    }
    
    private func performHierarchicalClustering(
        similarityMatrix: [[Float]],
        threshold: Float
    ) -> [[Int]] {
        
        let n = similarityMatrix.count
        guard n > 0 else { return [] }
        
        // Start with each speaker in their own cluster
        var clusters = (0..<n).map { [$0] }
        var activeClusters = Set(0..<n)
        
        // Distance matrix (inverse of similarity)
        let distances = similarityMatrix.map { row in
            row.map { 1.0 - $0 }
        }
        
        // Agglomerative clustering
        while activeClusters.count > 1 {
            // Find closest pair of clusters
            var minDistance: Float = Float.infinity
            var mergeI = -1
            var mergeJ = -1
            
            for i in activeClusters {
                for j in activeClusters where j > i {
                    // Average linkage
                    let avgDistance = averageDistance(
                        cluster1: clusters[i],
                        cluster2: clusters[j],
                        distances: distances
                    )
                    
                    if avgDistance < minDistance {
                        minDistance = avgDistance
                        mergeI = i
                        mergeJ = j
                    }
                }
            }
            
            // Check if we should stop merging (distance too large)
            if minDistance > (1.0 - threshold) {
                break
            }
            
            // Merge clusters
            clusters[mergeI].append(contentsOf: clusters[mergeJ])
            activeClusters.remove(mergeJ)
        }
        
        // Return only active clusters
        return activeClusters.sorted().map { clusters[$0] }
    }
    
    private func averageDistance(
        cluster1: [Int],
        cluster2: [Int],
        distances: [[Float]]
    ) -> Float {
        
        var totalDistance: Float = 0
        var count = 0
        
        for i in cluster1 {
            for j in cluster2 {
                totalDistance += distances[i][j]
                count += 1
            }
        }
        
        return count > 0 ? totalDistance / Float(count) : Float.infinity
    }
    
    private func assignGlobalSpeakerIds(
        clusters: [[Int]],
        chunkSpeakers: [ChunkSpeaker]
    ) -> [String: String] {
        
        var globalMap: [String: String] = [:]
        
        for (clusterIdx, cluster) in clusters.enumerated() {
            let globalId = "Speaker \(clusterIdx + 1)"
            
            for speakerIdx in cluster {
                let speaker = chunkSpeakers[speakerIdx]
                let localKey = "\(speaker.chunkId)_\(speaker.localSpeakerId)"
                globalMap[localKey] = globalId
            }
        }
        
        return globalMap
    }
    
    private func createSpeakerProfiles(
        clusters: [[Int]],
        chunkSpeakers: [ChunkSpeaker],
        globalMap: [String: String]
    ) -> [SpeakerProfile] {
        
        var profiles: [SpeakerProfile] = []
        
        for (clusterIdx, cluster) in clusters.enumerated() {
            let globalId = "Speaker \(clusterIdx + 1)"
            
            // Collect all embeddings for this speaker
            let speakerEmbeddings = cluster.map { chunkSpeakers[$0].embedding }
            let durations = cluster.map { 
                chunkSpeakers[$0].endTime - chunkSpeakers[$0].startTime 
            }
            let confidences = cluster.map { chunkSpeakers[$0].confidence }
            
            // Calculate average embedding
            let avgEmbedding = averageEmbeddings(speakerEmbeddings)
            
            // Calculate total duration
            let totalDuration = durations.reduce(0, +)
            
            // Calculate average confidence
            let avgConfidence = confidences.reduce(0, +) / Float(confidences.count)
            
            let profile = SpeakerProfile(
                globalId: globalId,
                averageEmbedding: avgEmbedding,
                sampleCount: cluster.count,
                totalDuration: totalDuration,
                confidence: avgConfidence
            )
            
            profiles.append(profile)
        }
        
        return profiles
    }
    
    private func averageEmbeddings(_ embeddings: [[Float]]) -> [Float] {
        guard !embeddings.isEmpty else { return [] }
        
        let dimension = embeddings[0].count
        var average = Array(repeating: Float(0), count: dimension)
        
        for embedding in embeddings {
            for i in 0..<dimension {
                average[i] += embedding[i]
            }
        }
        
        let count = Float(embeddings.count)
        for i in 0..<dimension {
            average[i] /= count
        }
        
        // Normalize the average embedding
        var norm: Float = 0
        vDSP_svesq(average, 1, &norm, vDSP_Length(dimension))
        
        if norm > 0 {
            var scale = 1.0 / sqrt(norm)
            vDSP_vsmul(average, 1, &scale, &average, 1, vDSP_Length(dimension))
        }
        
        return average
    }
}

// MARK: - Extensions

extension SpeakerUnificationService {
    
    /// Create a formatted report of speaker unification results
    func generateReport(from result: UnificationResult) -> String {
        var report = "Speaker Unification Report\n"
        report += String(repeating: "=", count: 40) + "\n\n"
        
        report += "Unique Speakers: \(result.speakerProfiles.count)\n\n"
        
        for profile in result.speakerProfiles {
            report += "\(profile.globalId):\n"
            report += "  Segments: \(profile.sampleCount)\n"
            report += "  Duration: \(String(format: "%.1f", profile.totalDuration))s\n"
            report += "  Confidence: \(String(format: "%.2f", profile.confidence))\n"
        }
        
        if let matrix = result.similarityMatrix, matrix.count <= 10 {
            report += "\nSimilarity Matrix:\n"
            for row in matrix {
                let formatted = row.map { String(format: "%.2f", $0) }.joined(separator: " ")
                report += formatted + "\n"
            }
        }
        
        return report
    }
}
