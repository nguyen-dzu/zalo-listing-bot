# Design Patterns — Zalo Listing Bot

| Pattern | Class | File | Responsibility |
|---------|-------|------|----------------|
| Singleton | `AppConfig` | Config.ahk | Read all variables from `config.ini` |
| Strategy | `TableLoader` | TableLoader.ahk | Load tables from Excel COM, fallback to CSV |
| Repository | `GroupRegistry` | GroupRegistry.ahk | Source / main group lists |
| Specification | `BlockList` | BlockList.ahk | Decide whether a post is blocked |
| Strategy | `ListingParser` | Parser.ahk | Text → object, object → text |
| Repository | `ListingRepository` | Storage.ahk | Save/read objects + audit log |
| Repository | `HarvestStateStore` | StateStore.ahk | Harvest cursor, seen hashes |
| Repository | `PublishQueueStore` | QueueStore.ahk | Durable leases, journal, retries |
| Repository | `ListingMediaStore` | MediaStore.ahk | Clipboard archive paths |
| Builder | `MessageComposer` | Composer.ahk | Render one listing into one message |
| Adapter | `ZaloUIAdapter` | ZaloUI.ahk | Chrome focus + bridge + keystrokes |
| Adapter | `WebBridge` | WebBridge.ahk | HTTP localhost bridge to Tampermonkey |
| Service | `MessageHarvester` | Harvester.ahk | Orchestrate harvest loop |
| Service | `ListingMediaCapturer` | MediaCapturer.ahk | Archive images via DOM bridge |
| Service | `DurableListingPublisher` | Publisher.ahk | Resumable one-room publish |
| Facade | `ListingBotService` | Bot.ahk | One method per hotkey |

**Layer rules:** `Send`/`Click` only in `ZaloUI.ahk`; regex parse only in `Parser.ahk`.

Tests for pure logic live in `windows/tests/RunTests.ahk` and run without Chrome.
