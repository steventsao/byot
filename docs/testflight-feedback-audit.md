# TestFlight feedback audit — September 11, 2026

Work in progress. This audit covers all 55 screenshot submissions and both crash submissions returned by App Store Connect, sorted newest first. Raw comments, screenshots, emails, telemetry and signed URLs stay outside the repository. These dispositions distinguish current work from historical reports about features removed from this dedicated OpenCode client. A retired feature is not a newly fixed or revalidated feature.

Baseline: main `98a7ad27b0a9e4c9f0cd520c4407fed5417cc0ef`, byot 1.0.14. Current implementation/verification is still in progress; no new TestFlight release is claimed here.

Visual reference: OpenAI's [public Codex mobile demo](https://openai.com/index/work-with-codex-from-anywhere/), inspected in the browser. It shows a single rounded input surface, message above controls, add at the leading edge and send at the trailing edge. Direct native Codex inspection was unavailable through the computer-use tool.

| # | Submission | Report | Disposition | Implementation / evidence |
|---|---|---|---|---|
| 1 | `ADTarIsuo0awzMqBkovv7XA` | Server menu selection alignment | Implemented; UI verification pending | Native inline Picker in OpenCodeRootView; model picker rows also share icon width. |
| 2 | `AFxMuB4Mnoo3XLwDqB1fpE4` | Attachment preview | Implemented; UI verification pending | Downsampled image thumbnails and native image/document Quick Look, owned temporary files. |
| 3 | `AKkGDbj875uwPDWpzvZrbrk` | Composer organization | Implemented; UI verification pending | One container, full-width input, bottom attachment/model/send row. |
| 4 | `APT6N1smb-9vXxdyLccufMM` | Lowercase name and consistent brand font | In progress | Shared lowercase Open Runde wordmark; app icon font provenance still to verify. |
| 5 | `ACeLM70lnaQP34bA5X0e_I0` | Search and compose on the same bottom row | Implemented; UI verification pending | Bottom search field with clear action and adjacent compose control. |
| 6 | `ABcgbfTZ_z23FVUZPMUnYQM` | Server bar and optional project grouping/sorts | Existing; regression pending | OpenCodeServerBar, OpenCodeSessionBrowserStore; flat/grouped recent/status/name sorts. |
| 7 | `AJdDjrxl4r4FFpJ646T_ZBU` | Meaningful session state and recency | Existing; regression pending | OpenCodeSessionRow uses status glyph, status text and relative activity time. |
| 8 | `ADZMRhL_G2pzzGcReIy7Hrs` | Light/dark contrast | Existing; regression pending | BYOTAppearance and semantic colors; contrast and rendered appearance tests. |
| 9 | `ANy3NA4eHNR2IR5fHp0S56U` | Stalled session recovery | Existing; regression pending | OpenCodeSessionRecoveryTests cover interruption, idle/no reply, model failure and queue reconciliation. |
| 10 | `AMwMUX6Thn-FOxvFvbZQ6oA` | Left-aligned model selector in composer | Implemented; UI verification pending | Model control sits at the left of the input footer. |
| 11 | `ABvo_tDyM9LU6hFb4L2H0EM` | Remove separate queue-next hint | Implemented; UI verification pending | Queued prompts carry status in their message cards; no pre-send queue banner. |
| 12 | `AOl58SQ35AcwotHzXliER0E` | Pictures and file context | Existing plus preview changes; regression pending | Photos/file import, bounded attachment payloads, both protocol adapters and prompt queue. |
| 13 | `ABj8ESnYEkZFWD_VLrITugg` | Use byot branding instead of OpenCode as the app name | Implemented; UI verification pending | Root wordmark byot; OpenCode retained only where naming the actual server/protocol. |
| 14 | `AJoXZ3goD2B66PlAURTHMW8` | New chat with inline server/project selectors | Pending | Replace project-selection menu with a dedicated draft conversation screen. |
| 15 | `AF1q2jnxGSHgwCkbNlBp_Cg` | Edit saved server shows saved fields | Implemented; UI verification pending | Item-driven sheet atomically captures the selected profile and saved password. |
| 16 | `ABCr_LeQPU1gs9Ps8kk2JhY` | Windows connection invalid response | Existing; regression pending | Report predates v2 protocol negotiation. Minimal v2 health and Windows-style paths need current regression evidence. |
| 17 | `ANgdL769-A-59GglGvBzN98` | Conversation errors visible in session list | Pending | Retry errors are visible now; final provider failures returning to idle still need attention summaries. |
| 18 | `AABmkFjmRxi7p9YEo0hLHxA` | Remember model per server | Existing; regression pending | OpenCodeModelSelectionTests cover server defaults, explicit Automatic, per-session restoration and provider changes. |
| 19 | `APQgkyLMrRTnliVQ3CleJ3s` | Add project option | Existing; UX update pending | Other directory accepts a new project directory; include in inline new-chat flow. |
| 20 | `AKsDpgSZ-qESsnUFtrQ0s78` | Progressive loading without slow server blocking | Existing; regression pending | Only selected server loads; bounded project fan-out publishes each completed project. |
| 21 | `AJ_1RzAN0eTwQSmWi5NHhyk` | Stop current turn | Existing; regression pending | Abort control and recovery checks; attachment-only queue affordance fixed in this change. |
| 22 | `ALuK6Dbfqxcyi8191d8B-ds` | Stop then queue or steer | Existing; regression pending | OpenCodePromptQueue and SessionRecoveryTests; explicit pause/retry behavior. |
| 23 | `AHuJJMHaMpxabA97_9kGLNQ` | One coherent composer like Codex | Implemented; UI verification pending | Same container update as September feedback; optional voice feature remains retired. |
| 24 | `APEnpr9JThVSrJB-4Y_qNTA` | Replace jumbled working copy with activity animation | Pending | Keep meaningful retry/wait details; remove duplicate thinking/working transcript labels. |
| 25 | `APEBKK3RlGPEpg2h6HZPb10` | Remove disabled Agents tab, flatten server navigation | Existing; regression pending | Current BYOTApp opens OpenCodeRootView directly and has no Agents tab. |
| 26 | `AAzlxpHgmMvPpF7WQ29Pkm4` | Concise thinking label | Existing; regression pending | BYOTActivityPhase uses Thinking; pending glyph-only transcript presentation. |
| 27 | `AH3IjzlY-QR_Zzipws_Wnn4` | Clarify target server for new sessions | Pending | Inline new-chat context selectors and existing session context label. |
| 28 | `AKRPHq-WEUR2ue77WJwcITQ` | Readable tool blocks | Existing; regression pending | OpenCodeToolView and OpenCodeToolPresentation; inspect long commands and status layout. |
| 29 | `ADl1g_JBVzh0UpjnTTbJpyQ` | Remove old bottom tabs and flatten navigation | Existing; regression pending | Native NavigationStack and horizontal server bar replace the retired dual-tab app. |
| 30 | `AF6hJ3zFCm2mLLfiLHB2VWE` | Queue messages sent during work | Existing; regression pending | Bounded OpenCodePromptQueue preserves text/model/attachments and reconciles before dispatch. |
| 31 | `AJSGR-rw8-9eAp9VG1YXOL0` | Broken retry label / state | Existing; regression pending | Status moved out of squeezed toolbar into adaptive context row; queue/recovery checks. |
| 32 | `AJMOJeKDyEmB3oX3-AfAU2g` | Edit created native agent | Retired feature | Current app has no agent creation/editing or hosted-agent model. |
| 33 | `AGqUvtLdq1mXt4dC_x-yMzs` | Missing first user message in hosted Qwen chat | Retired flow; current regression pending | Screenshot is hosted-agent chat; current OpenCode optimistic transcript and reconciliation are separately tested. |
| 34 | `AARaNswiqFKYd1vOiNbDoOk` | Qwen hosted-agent initial conversation | Retired feature | Screenshot is the old native-agent home, absent from current app. |
| 35 | `AHRpBW6OQ9h2sr94ZjFY5Cs` | Provider icons and alignment in New agent form | Retired feature | Screenshot is the old New agent form. Current model rows receive shared alignment. |
| 36 | `ABdGhpPPz-SXJFRh_wl3_YU` | Ready but first hosted-agent message missing | Retired flow; current regression pending | Current OpenCode sending/reload/recovery receives independent regression coverage. |
| 37 | `AJZeysbbsDrSdsUyggsXHoo` | Hosted-agent sent messages missing | Retired flow; current regression pending | Screenshot is old Qwen Coder Review UI; current optimistic transcript receives independent coverage. |
| 38 | `ALyfMvC4h0zyx3H9xGuH_x0` | Sign-in required after authentication | Retired feature | Current app has no cloud/Apple sign-in; credentials are per-server HTTPS authentication in Keychain. |
| 39 | `AIaXizpIgX6-L9jGCQ9lR4k` | Legacy chat layout alignment | Retired flow; shared improvement | Current composer/navigation changes address corresponding layout concerns. |
| 40 | `AO35nflBAlyN0eCbvAPLDoo` | Model picker floating over legacy home | Retired flow; current regression pending | Screenshots show old provider-lane home; current model picker is a native navigable list sheet. |
| 41 | `AE1-t6RjEdGxc6bwtxwbwD4` | Flue connection error | Retired feature | Screenshot explicitly names FlueClient.FlueAPIError; current target has no Flue client. |
| 42 | `AFSXfQ14ipM8xrUc7MPIQBM` | Flue client failure | Retired feature | Screenshot is the removed Flue integration. |
| 43 | `AOvYeT_RCM0y-XVw_kzpzr8` | Legacy agent data format error | Retired feature | Screenshot is the old hosted-agent/channel UI; current v1/v2 typed contracts are separately tested. |
| 44 | `AC31sADby7KpLewqBjOptpk` | Legacy data decoding regression | Retired feature | Old hosted-agent/channel model is absent; current protocol decoder regressions remain required. |
| 45 | `ANbwGZDQkBY9eBRFI_fA0uM` | Hosted agent voice milestone announcements | Retired feature | No autonomous hosted-agent scheduling or speech service exists in the current client. |
| 46 | `AMyZb5xpF5C9tlYdRTvrKgQ` | Animated loading ellipsis | Existing; regression pending | BYOTActivityGlyph animates thinking/loading and respects Reduce Motion and scene phase. |
| 47 | `AJNb3YOVywXL2pN00xmdqvg` | Hosted agent publishing failure | Retired feature | No built-in agent publishing flow exists in the current app. |
| 48 | `ADQWLH7Nyvr46pU2KoWP0I8` | Hosted-agent webpage cards and avatars | Retired feature | Old hosted artifact-card system is absent; current OpenCode attachments are covered by the preview work. |
| 49 | `AEdJSFXnKQMvpzJNXMt1U2E` | Sticky navigation layout | Existing; regression pending | Native NavigationStack with safe-area context/composer; adaptive layout tests. |
| 50 | `AHLtJhg5rsukWXUB5JuMjSQ` | Hosted HTML worker artifact viewer | Retired feature | Current app does not create/publish Cloudflare workers or use the old artifact model. |
| 51 | `AIQVCK8mBDwrzpRq4uE0OQk` | Keyboard dismissal and workspace tool output | Existing; regression pending | Interactive keyboard dismissal, model sheet focus dismissal and OpenCodeToolView. |
| 52 | `AHjqVb23zLPAGrQSnNj97uo` | Hosted Kimi tool-call protocol parsing | Retired feature | Screenshot shows raw model protocol tokens from the old hosted-agent backend; current upstream adapters normalize structured tool events. |
| 53 | `ALkFOHj1J8EW8B-CnDA3L2E` | Optimistic user message and duplicate loading replies | Retired flow; current regression pending | Current OpenCode transcript reducer/queue tests and live acceptance must prove optimistic message and no duplicate response. |
| 54 | `AOsrpdW13z7h4AIkgla0FB0` | Repeated early sign-in issue | Retired feature; screenshot unavailable | Apple returned HTTP 500 for the historical screenshot after retries. Comment alone says Again; no current flow can be inferred. |
| 55 | `AJx7Bta1cG48-Uz_MLKXBRQ` | Apple sign-in error | Retired feature | Screenshot shows Continue with Apple and missing Apple credential; no Apple sign-in in the current target. |

## Crash submissions

`AJs_L01_rULwz7RyHfrHKgs` and `APqAcbXKVt7MNKw63rvCUJw` both contain `EXC_BREAKPOINT` / `_dispatch_assert_queue_fail` in `AgentVoiceInputController.requestPermissions`. Both concern the old 0.1.6 voice implementation. The current Sources target contains no AgentVoiceInputController, speech service or microphone permission request. This is a removed code path, not a newly verified voice fix.

## Verification still required

- Native image/document previews, cancellation preserving drafts, filename confinement and cleanup, attachment-only queue control.
- Bottom search/compose placement, server menu selection and saved-profile editing; normal and Accessibility XXXL layouts.
- Inline new-chat server/project flow and session-list terminal failures.
- Full current unit/regression suite and live v1/v2 acceptance; release archive inspection if distributed.
