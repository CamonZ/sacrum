---
version: alpha
name: Articulated
description: Vertebrae's design system — monochrome surfaces, a single persimmon accent, Geist typography, and structural rhythm that suggests a spine without ever drawing one.
colors:
  bg: "#0a0a0a"
  surface: "#111111"
  surface-raised: "#161616"
  border: "#1f1f1f"
  border-strong: "#2a2a2a"
  text-primary: "#f4f1ec"
  text-secondary: "#b8b5af"
  text-muted: "#6f6c66"
  accent: "#ff5c2e"
  accent-hover: "#e84a1e"
  accent-fg: "#0a0a0a"
  success: "#22c55e"
  warning: "#eab308"
  error: "#ef4444"
  bg-light: "#f7f4ee"
  surface-light: "#ffffff"
  border-light: "#e6e1d7"
  border-strong-light: "#c9c3b5"
  text-primary-light: "#0a0a0a"
  text-secondary-light: "#4a4742"
  text-muted-light: "#807c75"
typography:
  display:
    fontFamily: "Geist"
    fontSize: "4.5rem"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "-0.02em"
  display-lg:
    fontFamily: "Geist"
    fontSize: "5rem"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "-0.025em"
  heading:
    fontFamily: "Geist"
    fontSize: "1.125rem"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "Geist"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0"
  body-sm:
    fontFamily: "Geist"
    fontSize: "0.875rem"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0"
  caption:
    fontFamily: "Geist"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "0.01em"
  mono:
    fontFamily: "Geist Mono"
    fontSize: "0.875rem"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "0"
  label:
    fontFamily: "Geist"
    fontSize: "0.875rem"
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: "0"
rounded:
  none: "0"
  sm: "0.25rem"
  md: "0.5rem"
  lg: "0.75rem"
  pill: "9999px"
spacing:
  0: "0"
  1: "0.25rem"
  2: "0.5rem"
  3: "0.75rem"
  4: "1rem"
  6: "1.5rem"
  8: "2rem"
  12: "3rem"
  16: "4rem"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.accent-fg}"
    typography: "{typography.label}"
    rounded: "{rounded.md}"
    padding: "{spacing.3} {spacing.4}"
  button-primary-hover:
    backgroundColor: "{colors.accent-hover}"
  input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "{spacing.3} {spacing.4}"
  input-focus:
    borderColor: "{colors.accent}"
  surface:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.lg}"
    padding: "{spacing.6}"
---

# Articulated

The design system for Vertebrae.

## Overview

Articulated is the visual language for Vertebrae, a hosted product for orchestrating AI agent workflows. The brand voice is **technical, playful, precise** — built for indie developers who want opinionated tools, not generic SaaS.

The aesthetic is restrained. One confident accent (persimmon), warm neutrals, and tight typographic rhythm carry the personality. There are no illustrations, mascots, gradients, glow effects, or stock "AI startup" hero graphics. Surfaces are composed of type, tokens, and structural rhythm.

The spine metaphor — the namesake of the product — is **suggested**, never literal. No vertebra anatomy, no x-ray imagery, no spine glyph in the wordmark. The metaphor lives in segmented rules, articulated step chains, and rhythmic structural elements that imply articulation through composition.

Posture: opinionated and bold but quiet. Closer to Linear than to Vercel. Density is tight. Motion is restrained.

## Colors

The palette is monochromatic with a single shared accent. **Persimmon `#ff5c2e`** is the only accent color in either theme; it appears at identical hex in dark and light. Status colors (success/warning/error) are designed per-theme to remain accessible against their respective backgrounds.

Both themes use **warm neutrals**, not cool greys. Dark text is `#f4f1ec` (warm off-white, not pure white). Light background is `#f7f4ee` (warm off-white, not stark white). Pure white and pure black appear only as the light background's elevated surfaces and as accent text.

### Dark theme (default)

| Token | Hex | Role |
| --- | --- | --- |
| `bg` | `#0a0a0a` | Page background |
| `surface` | `#111111` | Cards, panels, raised surfaces |
| `surface-raised` | `#161616` | Surfaces above other surfaces |
| `border` | `#1f1f1f` | Standard 1px divider |
| `border-strong` | `#2a2a2a` | Emphasized divider |
| `text-primary` | `#f4f1ec` | Body, headings |
| `text-secondary` | `#b8b5af` | Secondary copy |
| `text-muted` | `#6f6c66` | De-emphasized labels, timestamps |

### Light theme

| Token | Hex | Role |
| --- | --- | --- |
| `bg` | `#f7f4ee` | Page background |
| `surface` | `#ffffff` | Cards, panels |
| `surface-raised` | `#ffffff` | Raised surfaces |
| `border` | `#e6e1d7` | Standard divider |
| `border-strong` | `#c9c3b5` | Emphasized divider |
| `text-primary` | `#0a0a0a` | Body, headings |
| `text-secondary` | `#4a4742` | Secondary copy |
| `text-muted` | `#807c75` | De-emphasized labels |

### Shared

| Token | Hex | Role |
| --- | --- | --- |
| `accent` | `#ff5c2e` | Primary actions, focus, active states |
| `accent-hover` | `#e84a1e` | Accent hover state (darker, never lighter) |
| `accent-fg` | `#0a0a0a` | Text on accent surfaces |
| `success` | `#22c55e` | Positive state |
| `warning` | `#eab308` | Caution state |
| `error` | `#ef4444` | Failure state |

Theme selection follows the user's OS via `prefers-color-scheme` when no explicit choice is made; explicit choice persists in `localStorage` under `phx:theme` and applies as `data-theme="dark"` or `data-theme="light"` on `<html>`.

## Typography

Two type families, no third. **Geist Sans** carries the typographic system. **Geist Mono** is a first-class family used for IDs, timestamps, numerics, step labels, version stamps, and code — not exclusively for `<code>`.

Loaded weights: Sans 400/500/600/700; Mono 400/500. No additional weights, no script, no serif accent.

| Level | Family | Size | Weight | Line height | Letter spacing | Use |
| --- | --- | --- | --- | --- | --- | --- |
| `display-lg` | Geist | 5rem | 700 | 1.05 | -0.025em | Marketing hero |
| `display` | Geist | 4.5rem | 700 | 1.05 | -0.02em | Section heroes |
| `heading` | Geist | 1.125rem | 600 | 1.3 | -0.01em | Card and section titles |
| `label` | Geist | 0.875rem | 500 | 1.4 | 0 | Buttons, form labels, dense UI |
| `body` | Geist | 1rem | 400 | 1.5 | 0 | Default body copy |
| `body-sm` | Geist | 0.875rem | 400 | 1.5 | 0 | Secondary body |
| `caption` | Geist | 0.75rem | 400 | 1.4 | 0.01em | Captions, footnotes |
| `mono` | Geist Mono | 0.875rem | 400 | 1.4 | 0 | IDs, timestamps, numerics, code |

## Layout & Spacing

Layout is content-led, not grid-led. There is no fixed column grid; widths are constrained by content (`max-w-md` for forms, `max-w-3xl` for prose-width hero, `max-w-6xl` for full-bleed product surfaces). Margins are generous; density inside surfaces is Linear-tight.

Spacing scale follows Tailwind's default 4px base unit. Common values: `1` (0.25rem), `2` (0.5rem), `3` (0.75rem), `4` (1rem), `6` (1.5rem), `8` (2rem), `12` (3rem), `16` (4rem). Custom values outside the scale are avoided.

Breakpoints follow Tailwind defaults (`sm` 640, `md` 768, `lg` 1024, `xl` 1280). Marketing surfaces typically reflow at `lg`.

## Elevation & Depth

This is a **flat system**. Box-shadows are not used for elevation anywhere — not on cards, not on buttons, not on inputs, not on modals.

Hierarchy is conveyed exclusively through:

1. **1px borders** in `border` or `border-strong`, sourced from the active theme's tokens.
2. **Tonal background shifts** — `surface` sits on `bg`; `surface-raised` sits on `surface`. The deltas are intentionally subtle (~6 lightness steps).

The single exception is **focus-visible rings**, which are 2px `accent` at 2px offset. These are not shadows and exist only for keyboard accessibility.

## Shapes

Corner radii are restrained. Three sizes carry almost everything; pill is reserved for tag-like affordances and the theme toggle.

| Token | Value | Use |
| --- | --- | --- |
| `none` | 0 | Dividers, plain rules |
| `sm` | 0.25rem | Micro-elements (chips, dots) |
| `md` | 0.5rem | Buttons, inputs, badges |
| `lg` | 0.75rem | Cards, panels, surfaces |
| `pill` | 9999px | Toggle indicators, status pills |

## Components

The system ships two custom design primitives that suggest the spine motif structurally:

### `<.spine_rule />`
A horizontal divider rendered as a row of short equal-length segments separated by gaps (default: 7 segments, 24px each, 6px gap, 1px tall, in `border` tone). Used between major sections instead of a continuous `<hr>`. Suggests articulation without a literal anatomical reference.

### `<.spine_chain steps={...} />`
A horizontal step indicator. Each step is `%{label, state}` where `state ∈ {:active, :completed, :pending}`. Steps are connected by a 1px `border-strong` segment with a small (4–6px) filled circle joint between them. Active uses `accent`; completed uses `text-secondary`; pending uses `text-muted`. Step labels render in `mono`.

### Buttons
Primary buttons are solid `accent` with `accent-fg` text. Hover swaps to `accent-hover` (a darker tone — never lighter, never glow). No icon-only variant unless space genuinely requires it.

### Inputs
Inputs sit on `surface` with a 1px `border`. Focus changes the border to `accent`; no ring, no shadow, no glow. Placeholder text is `text-muted`. Caret color matches `accent`.

### Cards & surfaces
Cards are `surface` with a 1px `border` and `lg` corner radius. Padding is generous (`spacing.6` typically). No shadow. Raised cards use `surface-raised` instead of elevation.

### Theme toggle
A pill-shaped 3-segment control: system / light / dark. The active segment slides via a CSS `transition-[left]` animation. Icons are heroicons-micro at 4×4. Only one form factor; no popover or menu variant.

## Do's and Don'ts

**Do**

- Use `accent` sparingly — one accented element per visual cluster.
- Use Geist Mono for anything resembling an identifier (IDs, timestamps, version numbers, step counts, code).
- Compose hierarchy from borders and tonal surfaces. Add a border before reaching for anything else.
- Treat the light theme as a designed surface in its own right — verify contrast and rhythm in both themes before shipping any component.
- Use `<.spine_rule />` between major page sections; one per logical break, not as decoration.
- Limit motion to 120–200ms ease-out cubic-bezier transitions. Hover states are tonal background or text shifts only.

**Don't**

- Don't introduce a third type family. Don't use a serif accent or a script display.
- Don't use Geist Mono for body copy or Geist Sans for IDs. Roles are fixed.
- Don't add box-shadows, glow effects, gradient text, aurora backgrounds, floating orbs, tilt effects, magnetic hovers, particle effects, or animated decorative shapes.
- Don't add literal vertebra anatomy, x-ray imagery, medical iconography, or a spine glyph in the wordmark. The metaphor is structural, not pictorial.
- Don't lighten, darken, or desaturate `accent` between themes — the hex is identical in both.
- Don't add new accent colors. The palette ships one. Status colors (`success`/`warning`/`error`) are not decorative — only use them for their semantic state.
- Don't preserve or reintroduce orange/amber tokens from any prior palette.
- Don't add scale-on-hover, bounce, spring, or glow-on-hover. Motion is restrained.
- Don't add wrapper `<div>`s purely for centering — collapse to one flex/grid container.
- Don't use pure white or pure black for body text or backgrounds. Use the warm neutrals defined above.
