import Accelerate
import TicketSearchCore

public struct KMeans {

    public let k: Int
    public let maxIterations: Int
    public let restarts: Int
    public let seed: UInt64

    public init(k: Int, maxIterations: Int = 300, restarts: Int = 10, seed: UInt64 = 42) {
        precondition(k > 0, "k must be positive")
        self.k = k
        self.maxIterations = maxIterations
        self.restarts = restarts
        self.seed = seed
    }

    public func fit(_ embeddings: Embeddings) -> Clustering {
        precondition(embeddings.count >= k, "need at least k points to form k clusters")

        var best: Clustering?
        for restart in 0 ..< restarts {
            var rng = SplitMix64(seed: seed &+ UInt64(restart))
            let candidate = runSingle(embeddings, rng: &rng)
            if best == nil || candidate.inertia < best!.inertia {
                best = candidate
            }
        }
        return best!
    }
}

// MARK: Lloyd

private extension KMeans {

    func runSingle(_ embeddings: Embeddings, rng: inout SplitMix64) -> Clustering {
        let x = embeddings.values
        let n = embeddings.count
        let d = embeddings.dim

        var centroids = plusPlusInit(x, n: n, d: d, rng: &rng)
        var labels = assign(x, n: n, d: d, centroids: centroids)

        for _ in 0 ..< maxIterations {
            centroids = updatedCentroids(x, n: n, d: d, labels: labels, rng: &rng)
            let next = assign(x, n: n, d: d, centroids: centroids)
            if next == labels { break }
            labels = next
        }

        return Clustering(
            labels: labels,
            centroids: Embeddings(values: centroids, count: k, dim: d),
            inertia: inertia(x, n: n, d: d, labels: labels, centroids: centroids)
        )
    }

    // Assign each point to its nearest centroid. Using ||x - μ||² = ||x||² − 2⟨x, μ⟩ + ||μ||²,
    // the constant ||x||² drops out of the argmin, so we only need ||μ||² − 2⟨x, μ⟩. The whole
    // cross-term matrix ⟨x, μ⟩ is one product X·Mᵀ (cblas_sgemm); the per-row argmin is vDSP_minvi.
    func assign(_ x: [Float], n: Int, d: Int, centroids: [Float]) -> [Int] {
        var cross = [Float](repeating: 0, count: n * k)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(n), Int32(k), Int32(d),
            1, x, Int32(d), centroids, Int32(d),
            0, &cross, Int32(k)
        )

        var centroidNormSq = [Float](repeating: 0, count: k)
        centroids.withUnsafeBufferPointer { buffer in
            for c in 0 ..< k {
                vDSP_svesq(buffer.baseAddress! + c * d, 1, &centroidNormSq[c], vDSP_Length(d))
            }
        }

        var labels = [Int](repeating: 0, count: n)
        var scores = [Float](repeating: 0, count: k)
        for i in 0 ..< n {
            for c in 0 ..< k {
                scores[c] = centroidNormSq[c] - 2 * cross[i * k + c]
            }
            var minValue: Float = 0
            var minIndex: vDSP_Length = 0
            vDSP_minvi(scores, 1, &minValue, &minIndex, vDSP_Length(k))
            labels[i] = Int(minIndex)
        }
        return labels
    }

    // Recompute each centroid as the mean of its assigned points. An empty cluster is reseeded
    // to a random point (deterministic via `rng`) so it can attract members on the next pass.
    func updatedCentroids(_ x: [Float], n: Int, d: Int, labels: [Int], rng: inout SplitMix64) -> [Float] {
        var centroids = [Float](repeating: 0, count: k * d)
        var counts = [Int](repeating: 0, count: k)

        for i in 0 ..< n {
            counts[labels[i]] += 1
            let base = labels[i] * d
            let source = i * d
            for j in 0 ..< d {
                centroids[base + j] += x[source + j]
            }
        }

        for c in 0 ..< k {
            let base = c * d
            if counts[c] > 0 {
                let scale = 1 / Float(counts[c])
                for j in 0 ..< d {
                    centroids[base + j] *= scale
                }
            } else {
                let point = Int.random(in: 0 ..< n, using: &rng) * d
                centroids[base ..< base + d] = x[point ..< point + d]
            }
        }
        return centroids
    }

    // k-means++ seeding: first centroid uniform at random, each subsequent one sampled with
    // probability proportional to its squared distance to the nearest centroid chosen so far.
    func plusPlusInit(_ x: [Float], n: Int, d: Int, rng: inout SplitMix64) -> [Float] {
        var centroids = [Float](repeating: 0, count: k * d)
        var closest = [Float](repeating: .greatestFiniteMagnitude, count: n)

        func place(_ centroid: Int, at point: Int) {
            centroids[centroid * d ..< centroid * d + d] = x[point * d ..< point * d + d]
            for i in 0 ..< n {
                let distance = squaredDistance(x, row: i, centroids: centroids, centroid: centroid, d: d)
                if distance < closest[i] { closest[i] = distance }
            }
        }

        place(0, at: Int.random(in: 0 ..< n, using: &rng))
        for c in 1 ..< k {
            let total = closest.reduce(0, +)
            guard total > 0 else {
                place(c, at: Int.random(in: 0 ..< n, using: &rng))
                continue
            }
            let target = Float.random(in: 0 ..< 1, using: &rng) * total
            var accumulated: Float = 0
            var chosen = n - 1
            for i in 0 ..< n {
                accumulated += closest[i]
                if accumulated >= target { chosen = i; break }
            }
            place(c, at: chosen)
        }
        return centroids
    }

    func inertia(_ x: [Float], n: Int, d: Int, labels: [Int], centroids: [Float]) -> Float {
        var total: Float = 0
        for i in 0 ..< n {
            total += squaredDistance(x, row: i, centroids: centroids, centroid: labels[i], d: d)
        }
        return total
    }

    func squaredDistance(_ x: [Float], row: Int, centroids: [Float], centroid: Int, d: Int) -> Float {
        var result: Float = 0
        x.withUnsafeBufferPointer { xBuffer in
            centroids.withUnsafeBufferPointer { cBuffer in
                vDSP_distancesq(xBuffer.baseAddress! + row * d, 1, cBuffer.baseAddress! + centroid * d, 1, &result, vDSP_Length(d))
            }
        }
        return result
    }
}

// MARK: RNG

// SplitMix64 — a small seedable generator so a fit is fully reproducible for a given seed
// (both k-means++ seeding and empty-cluster reseeding draw from it).
private struct SplitMix64: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
