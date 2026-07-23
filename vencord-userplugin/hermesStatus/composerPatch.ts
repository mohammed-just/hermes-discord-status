/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// Keep the expression parenthesized. CharacterCounter's composer patch has a
// `,\i` insertion anchor, so an unwrapped `,globalThis...` here is not safely
// composable when plugin patches are applied in the opposite order.
export const CURRENT_COMPOSER_REPLACEMENT = "$&(globalThis.Vencord?.Plugins?.plugins?.HermesStatus?.renderHermesStatusBar($1.id)??null),";
