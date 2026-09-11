# TestFlight feedback audit — September 11, 2026

This audit covers all 55 screenshot submissions and both crash submissions returned by App Store Connect, sorted newest first. Raw comments, screenshots, emails, telemetry and signed URLs stay outside the repository. These dispositions distinguish current work from historical reports about features removed from this dedicated OpenCode client. A retired feature is not a newly fixed or revalidated feature.

Baseline: main `98a7ad27b0a9e4c9f0cd520c4407fed5417cc0ef`, byot 1.0.14. Current fixes and regression evidence are recorded in the [1.0.15 release report](releases/1.0.15/README.md).

Visual reference: OpenAI's [public Codex mobile demo](https://openai.com/index/work-with-codex-from-anywhere/), inspected in the browser. It shows a single rounded input surface, message above controls, add at the leading edge and send at the trailing edge. Direct native Codex inspection was unavailable through the computer-use tool.

| # | Submission | Report | Disposition | Implementation / evidence |
|---|---|---|---|---|
| 1 | `ADTarIsuo0awzMqBkovv7XA` | Server menu selection alignment | Implemented; UI verified | Native inline Picker in OpenCodeRootView; model picker rows also share icon width. |
| 2 | `AFxMuB4Mnoo3XLwDqB1fpE4` | Attachment preview | Implemented; UI verified | Downsampled image thumbnails and native image/document Quick Look, owned temporary files. |
| 3 | `AKkGDbj875uwPDWpzvZrbrk` | Composer organization | Implemented; UI verified | One container, full-width input, bottom attachment/model/send row. |
| 4 | `APT6N1smb-9vXxdyLccufMM` | Lowercase name and consistent brand font | Implemented; visually verified | Shared lowercase Open Runde wordmark. The CoreGraphics icon generator reads the exact bundled OpenRunde-Bold.otf and renders all 15 icon sizes. |
| 5 | `ACeLM70lnaQP34bA5X0e_I0` | Search and compose on the same bottom row | Implemented; UI verified | Bottom search field with clear action and adjacent compose control. |
| 6 | `ABcgbfTZ_z23FVUZPMUnYQM` | Server bar and optional project grouping/sorts | Existing; verified on iOS 26.5 | Flat/grouped recent/status/name sorts, restoration and server switching passed on iOS 26.5. The iOS 26.3 simulator repeatedly missed the server tap; that runtime also failed standalone launch. See the release report limitation. |
| 7 | `AJdDjrxl4r4FFpJ646T_ZBU` | Meaningful session state and recency | Existing; regression passed | OpenCodeSessionRow uses status glyph, status text and relative activity time. |
| 8 | `ADZMRhL_G2pzzGcReIy7Hrs` | Light/dark contrast | Existing; regression passed | BYOTAppearance and semantic colors; contrast and rendered appearance tests. |
| 9 | `ANy3NA4eHNR2IR5fHp0S56U` | Stalled session recovery | Existing; regression passed | OpenCodeSessionRecoveryTests cover interruption, idle/no reply, model failure and queue reconciliation. |
| 10 | `AMwMUX6Thn-FOxvFvbZQ6oA` | Left-aligned model selector in composer | Implemented; UI verified | Model control sits at the left of the input footer. |
| 11 | `ABvo_tDyM9LU6hFb4L2H0EM` | Remove separate queue-next hint | Implemented; UI verified | Queued prompts carry status in their message cards; no pre-send queue banner. |
| 12 | `AOl58SQ35AcwotHzXliER0E` | Pictures and file context | Implemented; regression passed | Photos/file import, bounded attachment payloads, both protocol adapters and prompt queue. |
| 13 | `ABj8ESnYEkZFWD_VLrITugg` | Use byot branding instead of OpenCode as the app name | Implemented; UI verified | Root wordmark byot; OpenCode retained only where naming the actual server/protocol. |
| 14 | `AJoXZ3goD2B66PlAURTHMW8` | New chat with inline server/project selectors | Implemented; UI verified | Dedicated new-conversation page with centered server/project menus, optional working directory and explicit Start session; opens the selected context. |
| 15 | `AF1q2jnxGSHgwCkbNlBp_Cg` | Edit saved server shows saved fields | Implemented; UI verified | Item-driven sheet atomically captures the selected profile and saved password. |
| 16 | `ABCr_LeQPU1gs9Ps8kk2JhY` | Windows connection invalid response | Existing; protocol/path regression passed | Minimal v2 health detection, real v1/v2 acceptance and Windows-style directory fixtures passed. No live Windows host was tested. |
| 17 | `ANgdL769-A-59GglGvBzN98` | Conversation errors visible in session list | Implemented; regression passed | Per-server terminal errors survive navigation/relaunch, appear in rows and status sorting, and reconcile only known failures with bounded requests. |
| 18 | `AABmkFjmRxi7p9YEo0hLHxA` | Remember model per server | Existing; regression passed | OpenCodeModelSelectionTests cover server defaults, explicit Automatic, per-session restoration and provider changes. |
| 19 | `APQgkyLMrRTnliVQ3CleJ3s` | Add project option | Implemented; UI verified | Other directory is available in the new-conversation page; the UI creates and opens C:/work/new-project. |
| 20 | `AKsDpgSZ-qESsnUFtrQ0s78` | Progressive loading without slow server blocking | Existing; regression passed | Only selected server loads; bounded project fan-out publishes each completed project. |
| 21 | `AJ_1RzAN0eTwQSmWi5NHhyk` | Stop current turn | Existing; regression passed | Abort control and recovery checks; attachment-only queue affordance fixed in this change. |
| 22 | `ALuK6Dbfqxcyi8191d8B-ds` | Stop then queue or steer | Existing; regression passed | OpenCodePromptQueue and SessionRecoveryTests; explicit pause/retry behavior. |
| 23 | `AHuJJMHaMpxabA97_9kGLNQ` | One coherent composer like Codex | Implemented; UI verified | Same container update as September feedback; optional voice feature remains retired. |
| 24 | `APEnpr9JThVSrJB-4Y_qNTA` | Replace jumbled working copy with activity animation | Implemented; activity policy verified | Thinking/working transcript activity uses a glyph with an accessibility description; meaningful retry/wait details remain. BYOTActivityTests cover animation and Reduce Motion policy. |
| 25 | `APEBKK3RlGPEpg2h6HZPb10` | Remove disabled Agents tab, flatten server navigation | Existing; regression passed | Current BYOTApp opens OpenCodeRootView directly and has no Agents tab. |
| 26 | `AAzlxpHgmMvPpF7WQ29Pkm4` | Concise thinking label | Implemented; activity policy verified | Thinking remains the accessible phase name; the transcript uses the glyph-only presentation. |
| 27 | `AH3IjzlY-QR_Zzipws_Wnn4` | Clarify target server for new sessions | Implemented; UI verified | Server/project choices are visible before creating a session; the resulting chat exposes the correct server and full directory to accessibility. |
| 28 | `AKRPHq-WEUR2ue77WJwcITQ` | Readable tool blocks | Existing; regression and source review | OpenCodeToolPresentationTests cover readable titles and long commands. OpenCodeToolView uses leading alignment, bounded summaries, stacked large-text status and expandable input/output. |
| 29 | `ADl1g_JBVzh0UpjnTTbJpyQ` | Remove old bottom tabs and flatten navigation | Existing; regression passed | Native NavigationStack and horizontal server bar replace the retired dual-tab app. |
| 30 | `AF6hJ3zFCm2mLLfiLHB2VWE` | Queue messages sent during work | Existing; regression passed | Bounded OpenCodePromptQueue preserves text/model/attachments and reconciles before dispatch. |
| 31 | `AJSGR-rw8-9eAp9VG1YXOL0` | Broken retry label / state | Existing; regression passed | Status moved out of squeezed toolbar into adaptive context row; queue/recovery checks. |
| 32 | `AJMOJeKDyEmB3oX3-AfAU2g` | Edit created native agent | Retired feature | Current app has no agent creation/editing or hosted-agent model. |
| 33 | `AGqUvtLdq1mXt4dC_x-yMzs` | Missing first user message in hosted Qwen chat | Retired flow; current regression passed | Screenshot is hosted-agent chat; current OpenCode optimistic transcript and reconciliation are separately tested. |
| 34 | `AARaNswiqFKYd1vOiNbDoOk` | Qwen hosted-agent initial conversation | Retired feature | Screenshot is the old native-agent home, absent from current app. |
| 35 | `AHRpBW6OQ9h2sr94ZjFY5Cs` | Provider icons and alignment in New agent form | Retired feature | Screenshot is the old New agent form. Current model rows receive shared alignment. |
| 36 | `ABdGhpPPz-SXJFRh_wl3_YU` | Ready but first hosted-agent message missing | Retired flow; current regression passed | Current OpenCode sending/reload/recovery receives independent regression coverage. |
| 37 | `AJZeysbbsDrSdsUyggsXHoo` | Hosted-agent sent messages missing | Retired flow; current regression passed | Screenshot is old Qwen Coder Review UI; current optimistic transcript receives independent coverage. |
| 38 | `ALyfMvC4h0zyx3H9xGuH_x0` | Sign-in required after authentication | Retired feature | Current app has no cloud/Apple sign-in; credentials are per-server HTTPS authentication in Keychain. |
| 39 | `AIaXizpIgX6-L9jGCQ9lR4k` | Legacy chat layout alignment | Retired flow; shared improvement | Current composer/navigation changes address corresponding layout concerns. |
| 40 | `AO35nflBAlyN0eCbvAPLDoo` | Model picker floating over legacy home | Retired flow; current regression passed | Screenshots show old provider-lane home; current model picker is a native navigable list sheet. |
| 41 | `AE1-t6RjEdGxc6bwtxwbwD4` | Flue connection error | Retired feature | Screenshot explicitly names FlueClient.FlueAPIError; current target has no Flue client. |
| 42 | `AFSXfQ14ipM8xrUc7MPIQBM` | Flue client failure | Retired feature | Screenshot is the removed Flue integration. |
| 43 | `AOvYeT_RCM0y-XVw_kzpzr8` | Legacy agent data format error | Retired feature | Screenshot is the old hosted-agent/channel UI; current v1/v2 typed contracts are separately tested. |
| 44 | `AC31sADby7KpLewqBjOptpk` | Legacy data decoding regression | Retired feature | Old hosted-agent/channel model is absent; current protocol decoder regressions remain required. |
| 45 | `ANbwGZDQkBY9eBRFI_fA0uM` | Hosted agent voice milestone announcements | Retired feature | No autonomous hosted-agent scheduling or speech service exists in the current client. |
| 46 | `AMyZb5xpF5C9tlYdRTvrKgQ` | Animated loading ellipsis | Existing; regression passed | BYOTActivityGlyph animates thinking/loading and respects Reduce Motion and scene phase. |
| 47 | `AJNb3YOVywXL2pN00xmdqvg` | Hosted agent publishing failure | Retired feature | No built-in agent publishing flow exists in the current app. |
| 48 | `ADQWLH7Nyvr46pU2KoWP0I8` | Hosted-agent webpage cards and avatars | Retired feature | Old hosted artifact-card system is absent; current OpenCode attachments are covered by the preview work. |
| 49 | `AEdJSFXnKQMvpzJNXMt1U2E` | Sticky navigation layout | Existing; regression passed | Native NavigationStack with safe-area context/composer; adaptive layout tests. |
| 50 | `AHLtJhg5rsukWXUB5JuMjSQ` | Hosted HTML worker artifact viewer | Retired feature | Current app does not create/publish Cloudflare workers or use the old artifact model. |
| 51 | `AIQVCK8mBDwrzpRq4uE0OQk` | Keyboard dismissal and workspace tool output | Existing; regression passed | Interactive keyboard dismissal, model sheet focus dismissal and OpenCodeToolView. |
| 52 | `AHjqVb23zLPAGrQSnNj97uo` | Hosted Kimi tool-call protocol parsing | Retired feature | Screenshot shows raw model protocol tokens from the old hosted-agent backend; current upstream adapters normalize structured tool events. |
| 53 | `ALkFOHj1J8EW8B-CnDA3L2E` | Optimistic user message and duplicate loading replies | Retired flow; current regression passed | Current OpenCode transcript reducer/queue tests and live acceptance must prove optimistic message and no duplicate response. |
| 54 | `AOsrpdW13z7h4AIkgla0FB0` | Repeated early sign-in issue | Retired feature; screenshot unavailable | Apple returned HTTP 500 for the historical screenshot after retries. Comment alone says Again; no current flow can be inferred. |
| 55 | `AJx7Bta1cG48-Uz_MLKXBRQ` | Apple sign-in error | Retired feature | Screenshot shows Continue with Apple and missing Apple credential; no Apple sign-in in the current target. |

## Crash submissions

`AJs_L01_rULwz7RyHfrHKgs` and `APqAcbXKVt7MNKw63rvCUJw` both contain `EXC_BREAKPOINT` / `_dispatch_assert_queue_fail` in `AgentVoiceInputController.requestPermissions`. Both concern the old 0.1.6 voice implementation. The current Sources target contains no AgentVoiceInputController, speech service or microphone permission request. This is a removed code path, not a newly verified voice fix.

## Verification

The [release report](releases/1.0.15/README.md) retains original summaries, focused reruns and unedited screenshots. All 19 distinct appearance/attachment/navigation checks and 190 distinct upstream/regression checks have a passing run across the documented simulator versions; these are not single uninterrupted green runs. Counts overlap for unit tests shared by the two runners. The iOS 26.3 server-tap and launch limitation remains explicit. Historical tester screenshots, crash payloads and private account information remain outside the repository.
