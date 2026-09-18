import { icon } from "./icons.ts";

export function renderPreview(): string {
  return `<div class="preview" id="experience">
    <div class="phone-shell">
      <div class="phone-screen">
        <div class="status-bar" aria-hidden="true"><span>9:41</span><span class="dynamic-island"></span><span class="status-icons"><svg width="16" height="13" viewBox="0 0 16 13" fill="currentColor"><rect x="0" y="8" width="3" height="5" rx="1"/><rect x="4" y="5" width="3" height="8" rx="1"/><rect x="8" y="2" width="3" height="11" rx="1"/><rect x="12" width="3" height="13" rx="1"/></svg><svg width="17" height="13" viewBox="0 0 20 15" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M2 4a13 13 0 0 1 16 0M5 8a8 8 0 0 1 10 0m-7 4a3 3 0 0 1 4 0"/></svg><span class="battery"></span></span></div>
        <div class="app-toolbar" aria-hidden="true"><span class="toolbar-control">${icon("back")}</span><span class="toolbar-control">${icon("menu")}</span><span class="session-title">Polish the upload flow</span><span class="toolbar-control">${icon("files")}</span></div>
        <div class="app-connection"><span class="status-dot"></span>MacBook Pro<span class="connection-divider">/</span>acme-app</div>

        <div class="preview-panels">
          <div class="preview-panel" id="panel-session" role="tabpanel" aria-labelledby="tab-session" tabindex="0">
            <div class="user-message">Give the upload flow a little polish.</div>
            <div class="agent-label">${icon("terminal")}<span>Build</span></div>
            <p class="agent-message">I’ll clean up the upload flow and run the tests.</p>
            <div class="tool-card"><span class="tool-icon">${icon("check")}</span><div><strong>Read files</strong><span>upload.tsx, button.tsx</span></div><span class="tool-chevron">${icon("chevron")}</span></div>
            <div class="tool-card"><span class="tool-icon">${icon("check")}</span><div><strong>Edit file</strong><span>components/upload.tsx</span></div><span class="change-count">+18 <i>−6</i></span></div>
            <div class="tool-card"><span class="tool-icon">${icon("check")}</span><div><strong>Shell command</strong><span>npm test</span></div><span class="tool-chevron">${icon("chevron")}</span></div>
            <div class="agent-label result-label">${icon("terminal")}<span>Build</span></div>
            <p class="agent-message result-message">A cleaner flow, ready to go.<br><span>All 12 tests passed.</span></p>
            <div class="turn-status">${icon("check")}<span>Session complete</span><span class="elapsed">8s</span></div>
          </div>

          <div class="preview-panel" id="panel-changes" role="tabpanel" aria-labelledby="tab-changes" tabindex="0" hidden>
            <div class="panel-heading"><p class="panel-title">A closer look.</p><p>Every change, right here.</p></div>
            <div class="diff-summary">${icon("diff")}<span>1 file changed</span><span class="change-count">+18 <i>−6</i></span></div>
            <div class="diff-card"><div class="diff-filename">${icon("files")}components/upload.tsx</div><div class="diff-code" aria-label="Example diff replacing a basic upload button with an accessible button and progress state"><div class="code-context">  return (</div><div class="code-removed">−   &lt;button onClick={upload}&gt;</div><div class="code-removed">−     Upload</div><div class="code-added">+   &lt;Button</div><div class="code-added">+     onClick={upload}</div><div class="code-added">+     disabled={isUploading}</div><div class="code-added">+     aria-busy={isUploading}</div><div class="code-added">+   &gt;</div><div class="code-added">+     {isUploading</div><div class="code-added">+       ? "Uploading…"</div><div class="code-added">+       : "Upload file"}</div><div class="code-added">+   &lt;/Button&gt;</div><div class="code-context">  );</div></div></div>
            <div class="review-note">${icon("check")}Ready for your review</div>
          </div>

          <div class="preview-panel" id="panel-permissions" role="tabpanel" aria-labelledby="tab-permissions" tabindex="0" hidden>
            <div class="user-message">Give the upload flow a little polish.</div>
            <div class="agent-label">${icon("terminal")}<span>Build</span></div>
            <p class="agent-message">The changes are ready. I’d like to run the test suite.</p>
            <div class="permission-card"><div class="permission-heading">${icon("shield")}<strong>Your call.</strong></div><p>Allow this shell command?</p><code>npm test</code><div class="permission-actions"><button type="button" data-permission="rejected">Reject</button><button type="button" data-permission="allowed">Allow once</button><button type="button" data-permission="always">Always allow</button></div></div>
            <p class="permission-result" role="status" aria-live="polite">Try a permission above. This is just a preview.</p>
          </div>
        </div>

        <div class="app-composer" aria-hidden="true"><div class="composer-options"><span>${icon("terminal")}Build</span><span>${icon("cpu")}Automatic model</span></div><div class="composer-input"><span>Message OpenCode</span><span class="send-control">${icon("up")}</span></div><div class="home-indicator"></div></div>
      </div>
    </div>
    <div class="preview-tabs" role="tablist" aria-label="Explore the app preview"><button id="tab-session" type="button" role="tab" aria-selected="true" aria-controls="panel-session" tabindex="0">${icon("terminal")}Session</button><button id="tab-changes" type="button" role="tab" aria-selected="false" aria-controls="panel-changes" tabindex="-1">${icon("diff")}Changes</button><button id="tab-permissions" type="button" role="tab" aria-selected="false" aria-controls="panel-permissions" tabindex="-1">${icon("shield")}Permissions</button></div>
    <p class="preview-caption">Explore a session. Make yourself at home.</p>
  </div>`;
}

// A self-contained preview. It never connects to a server or sends user input.
export const PREVIEW_SCRIPT = `
const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
function selectTab(tab) {
  tabs.forEach(item => {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  });
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) {
      event.preventDefault();
      selectTab(tabs[next]);
      tabs[next].focus();
    }
  });
});
const permissionResults = {
  rejected: 'Command rejected. You stay in control.',
  allowed: 'Allowed once. The test suite can run.',
  always: 'Permission saved. The test suite can run.'
};
document.querySelectorAll('[data-permission]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelector('.permission-result').textContent = permissionResults[button.dataset.permission];
    document.querySelectorAll('[data-permission]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  });
});
`;
