// The hero window is an illustration of Chostty's sidebar model. Everything in
// it — project names, commands, output — is made up.
(() => {
  "use strict";

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const esc = (s) =>
    String(s).replace(
      /[&<>"]/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c],
    );
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");

  // Palettes from Ghostty's bundled themes (background, foreground, palette 8/1/2/3/4).
  const THEMES = {
    "Catppuccin Mocha": {
      bg: "#1e1e2e",
      fg: "#cdd6f4",
      dim: "#585b70",
      c: ["#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa"],
    },
    "Gruvbox Dark": {
      bg: "#282828",
      fg: "#ebdbb2",
      dim: "#928374",
      c: ["#cc241d", "#98971a", "#d79921", "#458588"],
    },
    TokyoNight: {
      bg: "#1a1b26",
      fg: "#c0caf5",
      dim: "#414868",
      c: ["#f7768e", "#9ece6a", "#e0af68", "#7aa2f7"],
    },
    Nord: {
      bg: "#2e3440",
      fg: "#d8dee9",
      dim: "#596377",
      c: ["#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1"],
    },
    "Rose Pine Dawn": {
      bg: "#faf4ed",
      fg: "#575279",
      dim: "#9893a5",
      c: ["#b4637a", "#286983", "#ea9d34", "#56949f"],
    },
  };

  // Screen-reader announcements; the page language picks the table. Terminal
  // text inside the window stays English, as a real shell prints it.
  const MESSAGES = {
    en: {
      newWorkspace: (w) => `New workspace ${w}`,
      newTab: (t, w) => `New tab ${t} in ${w}`,
      paneCap: () => "This demo stops at four panes",
      split: (n, t) => `Split, ${n} panes in ${t}`,
      closedPane: (n) => `Closed pane, ${n} left`,
      closedTab: (t) => `Closed tab ${t}`,
      closedWorkspace: (w) => `Closed workspace ${w}`,
      lastPane: () => "Last pane stays open in the demo",
      noWorkspace: (n) => `No workspace ${n}`,
      workspace: (w) => `Workspace ${w}`,
      pane: (i, n) => `Pane ${i} of ${n}`,
      sidebarShown: () => "Sidebar shown",
      sidebarHidden: () => "Sidebar hidden",
      restarted: () =>
        "Restarted: same workspaces, tabs and splits, fresh shells",
    },
    ko: {
      newWorkspace: (w) => `${w} 워크스페이스를 만들었어요`,
      newTab: (t, w) => `${w}에 ${t} 탭을 만들었어요`,
      paneCap: () => "데모에서는 네 칸까지만 나눌 수 있어요",
      split: (n, t) => `${t} 탭을 ${n}칸으로 나눴어요`,
      closedPane: (n) => `칸을 닫았어요. ${n}칸 남았어요`,
      closedTab: (t) => `${t} 탭을 닫았어요`,
      closedWorkspace: (w) => `${w} 워크스페이스를 닫았어요`,
      lastPane: () => "데모에서는 마지막 칸은 닫지 않아요",
      noWorkspace: (n) => `${n}번 워크스페이스가 없어요`,
      workspace: (w) => `${w} 워크스페이스`,
      pane: (i, n) => `${n}칸 중 ${i}번째 칸`,
      sidebarShown: () => "사이드바를 열었어요",
      sidebarHidden: () => "사이드바를 닫았어요",
      restarted: () => "다시 켰어요. 배치는 그대로이고 셸만 새로 떴어요",
    },
  };
  const T = MESSAGES[document.documentElement.lang] || MESSAGES.en;

  const DOTS = [
    "#ffc27a",
    "#ff6f86",
    "#9db4ff",
    "#8fe3b0",
    "#d6a4ff",
    "#7fd6e8",
  ];
  const SPARE = [
    { name: "infra", dir: "~/work/infra", tabs: ["plan", "apply"] },
    { name: "notes", dir: "~/notes", tabs: ["today"] },
    { name: "blog", dir: "~/sites/blog", tabs: ["preview", "drafts"] },
    { name: "mobile", dir: "~/work/mobile", tabs: ["simulator"] },
    { name: "scratch", dir: "~/tmp", tabs: ["shell"] },
  ];
  const TAB_NAMES = ["logs", "repl", "db", "build", "docs", "ssh"];

  const pane = (dir, lines) => ({
    dir,
    lines,
    id: Math.random().toString(36).slice(2),
  });

  const OUT = {
    server: [
      ["t-2", "▸ listening on :8080"],
      ["t-dim", "GET /health 200 1.2ms"],
      ["t-dim", "GET /v1/users 200 8.4ms"],
    ],
    tests: [
      ["t-2", "✓ 148 passed"],
      ["t-3", "• 2 skipped"],
      ["t-dim", "done in 3.91s"],
    ],
    dev: [
      ["t-4", "VITE ready in 412 ms"],
      ["t-dim", "➜ Local: http://localhost:5173/"],
    ],
    git: [
      ["t-dim", "On branch main"],
      ["t-2", "nothing to commit, working tree clean"],
    ],
    plain: [],
  };

  const state = {
    sidebar: true,
    active: 0,
    lastWorkspace: 0,
    spare: 0,
    tabCount: 0,
    theme: "Catppuccin Mocha",
    workspaces: [
      {
        name: "api",
        dot: DOTS[0],
        tab: 0,
        tabs: [
          {
            name: "server",
            focus: 0,
            panes: [
              pane("~/work/api", ["cargo run", OUT.server]),
              pane("~/work/api", ["git status", OUT.git]),
            ],
          },
          {
            name: "tests",
            focus: 0,
            panes: [pane("~/work/api", ["cargo test", OUT.tests])],
          },
        ],
      },
      {
        name: "web",
        dot: DOTS[1],
        tab: 0,
        tabs: [
          {
            name: "dev",
            focus: 0,
            panes: [pane("~/work/web", ["npm run dev", OUT.dev])],
          },
        ],
      },
      {
        name: "dotfiles",
        dot: DOTS[2],
        tab: 0,
        tabs: [
          {
            name: "shell",
            focus: 0,
            panes: [pane("~/.config", ["", OUT.plain])],
          },
        ],
      },
    ],
  };

  const demo = $("#demo");
  if (!demo) return;
  const els = {
    sidebar: $("#demo-sidebar"),
    tabs: $("#demo-tabs"),
    panes: $("#demo-panes"),
    title: $("#demo-title"),
    status: $("#demo-status"),
    themeVal: $("#cf-theme"),
    swatches: $(".swatches"),
  };

  const ws = () => state.workspaces[state.active];
  const tab = () => ws().tabs[ws().tab];
  let fresh = { ws: -1, pane: null };

  const say = (msg) => {
    els.status.textContent = "";
    requestAnimationFrame(() => (els.status.textContent = msg));
  };

  function renderPane(p, focused) {
    const [cmd, out] = p.lines;
    const prompt = `<span class="t-4">${esc(p.dir)}</span> <span class="t-1">❯</span> `;
    const rows = [];
    if (p.login) rows.push(`<p class="t-dim">Last login: ${esc(p.login)}</p>`);
    if (cmd) {
      rows.push(`<p>${prompt}${esc(cmd)}</p>`);
      for (const [cls, text] of out)
        rows.push(`<p class="${cls}">${esc(text)}</p>`);
    }
    rows.push(`<p>${prompt}<span class="cursor"></span></p>`);
    return `<div class="pane${focused ? " is-focused" : ""}${fresh.pane === p.id ? " is-new" : ""}" data-pane="${p.id}">${rows.join("")}</div>`;
  }

  function render() {
    demo.classList.toggle("no-sidebar", !state.sidebar);
    $$('[data-act="sidebar"]').forEach(
      (b) =>
        b.hasAttribute("aria-pressed") &&
        b.setAttribute("aria-pressed", String(state.sidebar)),
    );

    els.sidebar.innerHTML = state.workspaces
      .map((w, i) => {
        const tabs = w.tabs
          .map(
            (t, j) =>
              `<li><button class="ws-tab" type="button" data-ws="${i}" data-tab="${j}" aria-current="${i === state.active && j === w.tab}">${esc(t.name)}</button></li>`,
          )
          .join("");
        return `<div class="ws${i === state.active ? " is-active" : ""}${fresh.ws === i ? " is-new" : ""}">
          <button class="ws-head" type="button" data-ws="${i}" style="--dot:${w.dot}" aria-current="${i === state.active}">
            <span class="ws-dot"></span>${esc(w.name)}<span class="ws-num">${i < 8 ? "⌘" + (i + 1) : ""}</span>
          </button><ul class="ws-tabs">${tabs}</ul></div>`;
      })
      .join("");

    els.tabs.innerHTML = ws()
      .tabs.map(
        (t, j) =>
          `<button class="tab" type="button" role="tab" data-ws="${state.active}" data-tab="${j}" aria-selected="${j === ws().tab}">${esc(t.name)}</button>`,
      )
      .join("");

    const t = tab();
    els.panes.innerHTML = t.panes
      .map((p, k) => renderPane(p, k === t.focus))
      .join("");
    els.title.textContent = `${ws().name} — ${t.name}`;
    fresh = { ws: -1, pane: null };
  }

  function applyTheme(key) {
    const th = THEMES[key];
    state.theme = key;
    const s = demo.style;
    s.setProperty("--term-bg", th.bg);
    s.setProperty("--term-fg", th.fg);
    s.setProperty("--term-dim", th.dim);
    th.c.forEach((c, i) => s.setProperty(`--term-${i + 1}`, c));
    if (els.themeVal) els.themeVal.textContent = key;
    $$(".swatch").forEach((b) =>
      b.setAttribute("aria-checked", String(b.dataset.theme === key)),
    );
  }

  const actions = {
    workspace() {
      const seed = SPARE[state.spare++ % SPARE.length];
      const n = state.workspaces.length;
      state.workspaces.push({
        name: n >= SPARE.length + 3 ? `${seed.name}-${n}` : seed.name,
        dot: DOTS[n % DOTS.length],
        tab: 0,
        tabs: seed.tabs.map((name) => ({
          name,
          focus: 0,
          panes: [pane(seed.dir, ["", OUT.plain])],
        })),
      });
      state.lastWorkspace = state.active;
      state.active = n;
      fresh.ws = n;
      say(T.newWorkspace(ws().name));
    },
    tab() {
      const w = ws();
      const name = TAB_NAMES[state.tabCount++ % TAB_NAMES.length];
      w.tabs.push({
        name,
        focus: 0,
        panes: [pane(tab().panes[0].dir, ["", OUT.plain])],
      });
      w.tab = w.tabs.length - 1;
      say(T.newTab(name, w.name));
    },
    split() {
      const t = tab();
      if (t.panes.length >= 4) {
        say(T.paneCap());
        return;
      }
      const p = pane(t.panes[t.focus].dir, ["", OUT.plain]);
      t.panes.splice(t.focus + 1, 0, p);
      t.focus += 1;
      fresh.pane = p.id;
      say(T.split(t.panes.length, t.name));
    },
    close() {
      const w = ws();
      const t = tab();
      if (t.panes.length > 1) {
        t.panes.splice(t.focus, 1);
        t.focus = Math.min(t.focus, t.panes.length - 1);
        say(T.closedPane(t.panes.length));
      } else if (w.tabs.length > 1) {
        w.tabs.splice(w.tab, 1);
        w.tab = Math.min(w.tab, w.tabs.length - 1);
        say(T.closedTab(t.name));
      } else if (state.workspaces.length > 1) {
        state.workspaces.splice(state.active, 1);
        state.active = Math.min(state.active, state.workspaces.length - 1);
        say(T.closedWorkspace(w.name));
      } else {
        say(T.lastPane());
      }
    },
    goto(n) {
      const i = n === 9 ? state.workspaces.length - 1 : n - 1;
      if (i < 0 || i >= state.workspaces.length) {
        say(T.noWorkspace(n));
        return;
      }
      if (i !== state.active) state.lastWorkspace = state.active;
      state.active = i;
      say(T.workspace(ws().name));
    },
    focusPane(dir) {
      const t = tab();
      t.focus = (t.focus + dir + t.panes.length) % t.panes.length;
      say(T.pane(t.focus + 1, t.panes.length));
    },
    sidebar() {
      state.sidebar = !state.sidebar;
      say(state.sidebar ? T.sidebarShown() : T.sidebarHidden());
    },
    restart() {
      const stamp = new Date().toLocaleTimeString("en-GB", {
        hour: "2-digit",
        minute: "2-digit",
      });
      const settle = () => {
        for (const w of state.workspaces)
          for (const t of w.tabs)
            for (const p of t.panes) {
              p.lines = ["", OUT.plain];
              p.login = `${stamp} on ttys0${Math.floor(Math.random() * 9)}`;
            }
        render();
        demo.classList.remove("is-restarting");
        say(T.restarted());
      };
      demo.scrollIntoView({
        behavior: reduced.matches ? "auto" : "smooth",
        block: "center",
      });
      if (reduced.matches) return settle();
      demo.classList.add("is-restarting");
      setTimeout(settle, 650);
      return "async";
    },
  };

  function run(act, arg) {
    if (!actions[act]) return;
    if (actions[act](arg) !== "async") render();
  }

  function pressCap(key) {
    const cap = $(`.capsrow .cap[data-key="${key}"]`);
    if (!cap) return;
    cap.classList.add("is-down");
    setTimeout(() => cap.classList.remove("is-down"), 140);
  }

  // Clicks: keycaps anywhere on the page, plus the window's own controls.
  document.addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.act) {
      run(b.dataset.act, Number(b.dataset.n) || undefined);
    } else if (b.dataset.ws !== undefined) {
      const i = Number(b.dataset.ws);
      if (i !== state.active) state.lastWorkspace = state.active;
      state.active = i;
      if (b.dataset.tab !== undefined)
        state.workspaces[i].tab = Number(b.dataset.tab);
      render();
    } else if (b.dataset.theme) {
      applyTheme(b.dataset.theme);
    }
  });

  els.panes.addEventListener("click", (e) => {
    const p = e.target.closest(".pane");
    if (!p) return;
    const t = tab();
    t.focus = t.panes.findIndex((x) => x.id === p.dataset.pane);
    render();
  });

  // Keys: only while the demo is on screen, never while typing, never stealing modified chords.
  let onScreen = false;
  new IntersectionObserver(([entry]) => (onScreen = entry.isIntersecting), {
    threshold: 0.25,
  }).observe(demo);

  const KEYMAP = {
    n: "workspace",
    t: "tab",
    d: "split",
    w: "close",
    b: "sidebar",
  };
  document.addEventListener("keydown", (e) => {
    if (!onScreen || e.altKey || e.ctrlKey || e.repeat) return;
    if (e.target.closest("input, textarea, select, [contenteditable]")) return;
    const key = e.key.toLowerCase();
    if (e.metaKey && "ntw".includes(key)) return; // the browser owns these
    let handled = true;
    if (KEYMAP[key]) run(KEYMAP[key]);
    else if (/^[1-9]$/.test(key)) run("goto", Number(key));
    else if (key === "[" || key === "]") run("focusPane", key === "[" ? -1 : 1);
    else handled = false;
    if (handled) {
      e.preventDefault();
      pressCap(key);
    }
  });

  // Theme swatches, drawn from the same palette table the window uses.
  if (els.swatches) {
    els.swatches.innerHTML = Object.entries(THEMES)
      .map(
        ([k, th]) =>
          `<button class="swatch" type="button" role="radio" aria-checked="false" data-theme="${esc(k)}">
            <span class="swatch-chip" style="--sw-bg:${th.bg}" aria-hidden="true">${th.c
              .slice(0, 3)
              .map((c) => `<i style="background:${c}"></i>`)
              .join("")}</span>${esc(k)}</button>`,
      )
      .join("");
  }

  render();
  applyTheme(state.theme);
})();
