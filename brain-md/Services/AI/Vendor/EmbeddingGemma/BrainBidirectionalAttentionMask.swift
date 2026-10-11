//
//  BrainBidirectionalAttentionMask.swift
//  brain-md
//
//  Vendored from ml-explore/mlx-swift-lm (MIT, Copyright © 2026 Apple Inc.), Libraries/MLXEmbedders/AttentionMask.swift at commit
//  38d14938da9cd58fc1e693229ba8a03813f3e147 (PR #654: bidirectional attention in EmbeddingGemma).
//  mlx-swift-lm 3.32.3 builds causal masks for EmbeddingGemma, which degrades its embeddings.
//  Types are renamed `Brain…` and registered over the package's `gemma3_text` in
//  `BrainEmbeddingGemmaRegistration`.
//  TODO: remove when mlx-swift-lm > 3.32.3 ships #654.
//

import MLX

/// Builds a bidirectional attention mask for encoder models.
///
/// Every query attends to keys within `halfWindow` positions on either side
/// (inclusive). With `halfWindow == nil` it attends to all keys. Zero entries
/// of `paddingMask` (`[batch, length]`) mask out the matching key columns.
/// The diagonal is always kept so that no row is fully masked.
///
/// Returns `.none` when `halfWindow` and `paddingMask` are both nil; otherwise a boolean
/// array of shape `[batch or 1, 1, length, length]`.
///
/// - Precondition: `length > 0`, `halfWindow >= 0` when given, and `paddingMask`
///   has shape `[batch, length]`.
nonisolated func brainBidirectionalAttentionMask(
    length: Int,
    halfWindow: Int?,
    paddingMask: MLXArray?
) -> MLXFast.ScaledDotProductAttentionMaskMode {
    precondition(length > 0, "length must be positive")
    if let halfWindow {
        precondition(halfWindow >= 0, "halfWindow must not be negative")
    }
    if let paddingMask {
        precondition(
            paddingMask.ndim == 2 && paddingMask.dim(1) == length,
            "paddingMask must have shape [batch, \(length)]")
    }

    // Nothing to mask: let attention take the fast path.
    if halfWindow == nil && paddingMask == nil { return .none }

    var mask: MLXArray
    if let halfWindow, halfWindow < length - 1 {
        // Band |i - j| <= halfWindow. A window covering the whole sequence
        // skips this branch, which also keeps Int.max away from Int32.
        let positions = MLXArray(0 ..< length)
        let distance = abs(positions[0..., .newAxis] - positions[.newAxis, 0...])
        mask = distance .<= MLXArray(Int32(halfWindow))
    } else {
        mask = MLXArray.ones([length, length], dtype: .bool)
    }
    mask = mask[.newAxis, .newAxis, 0..., 0...]

    if let paddingMask {
        // Mask key columns, not query rows: every query still sees the valid keys.
        let validKeys = paddingMask.asType(.bool)[0..., .newAxis, .newAxis, 0...]
        mask = mask .&& validKeys
    }

    // Keep the diagonal: a fully masked row gives kernel-dependent results.
    mask = mask .|| eye(length, type: Bool.self)

    return .array(mask)
}
