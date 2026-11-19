# Container Studio identity

A compact CS monogram: an open container frame around three connected horizontal rails. The negative space keeps it readable at small sizes. The mark is shared by the app icon, native sidebar, and setup screen.

- `logo-light.svg`: warm orange on light surfaces
- `logo-dark.svg`: blue on dark surfaces
- `logo-mono.svg`: one-color mark for templates
- `wordmark.svg`: name plus mark
- `app-icon.svg`: the macOS icon reference

The native app icon is [`Resources/AppIcon.icon`](../Resources/AppIcon.icon), an editable Apple Icon Composer document. Its original CS frame and rail are separate vector layers with Liquid Glass enabled, soft shadows, and light/dark color specializations. Open the document in Icon Composer to adjust materials and preview system appearances. Xcode compiles it into `Assets.car` and `AppIcon.icns`; the app does not override the system icon at runtime.

`icon-layers/` contains the original SVG inputs. The older `app-icon.svg`, `Studio.icns`, and `scripts/make-icon.swift` remain reference assets, outside the native packaging path. No external image or font service is required.
