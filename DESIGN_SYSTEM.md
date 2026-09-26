# Interview AI Design System

## Product Direction

Interview AI is a dark-mode-first, AI-native interview preparation product inspired by Linear, Cursor, Raycast, Claude Desktop, and Arc Browser. The product should feel calm, premium, fast, and spacious rather than like an internal developer utility.

## Color Tokens

| Token | Hex / Value | Tailwind |
| --- | --- | --- |
| Background | `#0B1020` | `bg-[#0B1020]` |
| Surface | `#111827` | `bg-[#111827]` |
| Surface Hover | `#1E293B` | `hover:bg-[#1E293B]` |
| Primary | `#6366F1` | `bg-[#6366F1] text-white` |
| Primary Hover | `#4F46E5` | `hover:bg-[#4F46E5]` |
| Success | `#22C55E` | `text-[#22C55E] bg-[#22C55E]/10` |
| Warning | `#F59E0B` | `text-[#F59E0B] bg-[#F59E0B]/10` |
| Text Primary | `#F8FAFC` | `text-[#F8FAFC]` |
| Text Secondary | `#94A3B8` | `text-[#94A3B8]` |
| Border | `rgba(255,255,255,0.06)` | `border-white/[0.06]` |

## Typography

Use Inter throughout.

| Role | Size / Weight | Tailwind |
| --- | --- | --- |
| Page title | `40px / 700` | `text-[40px] font-bold leading-tight` |
| Mobile page title | `32px / 700` | `text-[32px] font-bold leading-tight` |
| Section title | `24px / 600` | `text-2xl font-semibold` |
| Body | `16px / 400` | `text-base font-normal` |
| Body medium | `16px / 500` | `text-base font-medium` |
| Caption | `14px / 400` | `text-sm text-[#94A3B8]` |

## Radius, Shadow, Spacing

| Token | Value | Tailwind |
| --- | --- | --- |
| Card radius | `20px` | `rounded-[20px]` |
| Button radius | `16px` | `rounded-2xl` |
| Input radius | `16px` | `rounded-2xl` |
| Modal radius | `24px` | `rounded-3xl` |
| Premium shadow | `0 8px 32px rgba(0,0,0,0.35)` | `shadow-[0_8px_32px_rgba(0,0,0,0.35)]` |

Spacing scale: `4, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48`.

## Core Components

### Desktop App Shell

Tailwind: `min-h-screen bg-[#0B1020] text-[#F8FAFC] grid grid-cols-[280px_1fr]`

Sidebar: `bg-[#111827]/50 border-r border-white/[0.06] p-[18px]`

Navigation item: `h-[46px] px-3.5 rounded-2xl flex items-center gap-3 text-sm font-medium text-[#94A3B8] hover:bg-[#1E293B] data-[active=true]:bg-white/[0.075] data-[active=true]:text-[#F8FAFC]`

### Mobile App Shell

Bottom tab bar: `fixed bottom-0 inset-x-0 bg-[#111827]/90 backdrop-blur-xl border-t border-white/[0.06] px-2.5 py-2`

Tab item: `h-[58px] rounded-[18px] flex flex-col items-center justify-center gap-1 text-[11px] font-semibold text-[#94A3B8] data-[active=true]:bg-white/[0.075] data-[active=true]:text-[#F8FAFC]`

### Premium Card

Tailwind: `rounded-[20px] bg-[#111827]/80 border border-white/[0.06] shadow-[0_8px_32px_rgba(0,0,0,0.35)] p-5`

Hover: `hover:bg-[#1E293B]/80 transition-colors`

### Buttons

Primary: `h-[46px] px-[18px] rounded-2xl bg-[#6366F1] hover:bg-[#4F46E5] text-white text-sm font-medium`

Secondary: `h-[46px] px-[18px] rounded-2xl bg-white/[0.075] hover:bg-[#1E293B] text-[#F8FAFC] text-sm font-medium`

Ghost: `h-[46px] px-[18px] rounded-2xl bg-transparent hover:bg-white/[0.075] text-[#F8FAFC] text-sm font-medium`

### Inputs

Filled input: `min-h-12 px-3.5 py-3 rounded-2xl bg-white/[0.055] text-[#F8FAFC] placeholder:text-[#94A3B8]/70 outline-none focus:ring-2 focus:ring-[#6366F1]/40`

Avoid heavy outlines; use filled surfaces and subtle focus rings.

### Segmented Control

Container: `rounded-2xl bg-white/[0.055] p-1`

Item: `h-10 rounded-xl px-4 text-sm font-medium text-[#94A3B8] data-[active=true]:bg-[#6366F1] data-[active=true]:text-white`

## Screen Specifications

Home / Interview:
Hero title is `Interview AI`; subtitle is `Practice smarter. Ace your next interview.` Primary CTA is `Start Interview`; secondary CTA is `Knowledge Base`. Setup uses cards for Role, AI Model, Candidate Context, and Knowledge.

Knowledge Base:
Use asset cards with Title, Description, File count, Last updated, and Enabled status. Detail editing sits beside cards on desktop and stacks below cards on mobile.

History:
Use conversation cards. Each session displays Role, Date, Number of questions, and Knowledge base used. Conversation detail cards use status pills for question and answer labels.

Settings:
Provider selection is segmented. Model and key are shown first. API URL and local network tips are hidden inside Advanced Settings by default.

Interaction States:
Default surfaces are calm and low-contrast. Hover uses `#1E293B`. Primary press darkens to `#4F46E5`. Disabled buttons reduce opacity to roughly 45%. Focus uses an indigo glow instead of a hard border.
