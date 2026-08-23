import { invoke } from "@tauri-apps/api/core";
import { createIcons, icons } from "lucide";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import "./styles.css";

const isTauri = Boolean(window.__TAURI_INTERNALS__);
const view = new URLSearchParams(window.location.search).get("view") || "main";
const app = document.querySelector("#app");
const currentWindow = isTauri ? getCurrentWindow() : null;
let appEventsBound = false;

// 悬浮任务板窗口需要透明背景，才能让面板半透明并透出桌面；
// 主窗口保持不透明画布。
if (view === "board") document.body.classList.add("board-mode");

const state = {
  snapshot: null,
  section: "today",
  busy: false,
  error: "",
  editingTaskId: null,
};

const demoSnapshot = {
  referenceDate: "2026-08-17",
  header: "DDL · 3个月零0天",
  subtitle: "西安 · 5个月零15天",
  lunarDate: "农历七月初五",
  lunarAnnotation: "立秋",
  tasks: [
    { id: "demo-1", title: "自建代理节点", timeType: "day", periodStart: "2026-08-17", questLine: "main", state: "pending", recurrence: "once", periodLabel: "2026年8月17日" },
    { id: "demo-2", title: "铲屎", timeType: "day", periodStart: "2026-08-17", questLine: "main", state: "pending", recurrence: "repeat", periodLabel: "每天" },
    { id: "demo-3", title: "搞定测试 digital-brain，更新数据", timeType: "day", periodStart: "2026-08-17", questLine: "main", state: "completed", recurrence: "once", periodLabel: "2026年8月17日" },
    { id: "demo-4", title: "开发一个记账工具", timeType: "day", periodStart: "2026-08-17", questLine: "side", state: "pending", recurrence: "once", periodLabel: "2026年8月17日" },
    { id: "demo-5", title: "学会弹吉他", timeType: "day", periodStart: "2026-08-12", questLine: "extra", state: "pending", recurrence: "once", periodLabel: "2026年8月12日" },
  ],
  statistics: { endedPeriods: { completed: 0, pass: 0 }, byTimeType: {}, byQuestLine: {} },
  board: { opacityPercent: 80, alwaysOnTop: true, clickThrough: false, desktopWidget: false },
  displayConfig: { headerTemplate: "今日任务", subtitleTemplate: "", startDate: "2026-08-17", deadlineDate: "2026-08-17" },
  sync: { configuredMode: null, running: false, pending: false, lastSuccessfulAt: null, lastError: null },
  localSync: { enabled: false, endpoint: null, vaultId: null, pairing: null },
  shortcutError: null,
  shortcuts: [],
};

const navGroups = [
  { label: "任务与统计", items: [
    ["today", "今日", "sun"], ["tomorrow", "明日", "calendar-days"], ["week", "本周", "calendar-range"],
    ["month", "本月", "calendar"], ["someday", "闲时", "sparkles"], ["history", "历史", "history"], ["statistics", "统计", "chart-no-axes-combined"],
  ] },
  { label: "设置", items: [["display", "显示", "panels-top-left"], ["shortcuts", "快捷键", "command"], ["sync", "同步", "refresh-cw"]] },
];

function escapeHtml(value = "") {
  return String(value).replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[character]));
}

function icon(name, size = 17) {
  return `<i data-lucide="${name}" width="${size}" height="${size}" aria-hidden="true"></i>`;
}

function refreshIcons() {
  createIcons({ icons, attrs: { "stroke-width": 1.8 } });
}

async function invokeCommand(command, payload) {
  if (!isTauri) return demoSnapshot;
  return invoke(command, payload);
}

async function loadSnapshot() {
  try {
    state.snapshot = isTauri ? await invokeCommand("get_snapshot") : structuredClone(demoSnapshot);
    state.error = state.snapshot.shortcutError || "";
  } catch (error) {
    state.error = String(error);
  }
  render();
}

async function bindAppEvents() {
  if (!isTauri || appEventsBound) return;
  appEventsBound = true;
  await listen("tray://refresh", () => loadSnapshot());
  await listen("local-pairing://request", () => loadSnapshot());
  await listen("local-pairing://settled", () => loadSnapshot());
  await listen("hotkey://error", (event) => {
    state.error = String(event.payload || "快捷键不可用");
    render();
  });
  await listen("hotkey://command", (event) => {
    const action = String(event.payload || "");
    if (action === "quick-add") openTaskDialog(null);
  });
  if (view !== "main") return;
  await listen("tray://new-task", () => openTaskDialog(null));
  await listen("tray://settings", () => {
    state.section = "display";
    render();
  });
}

function taskScope(task) {
  if (task.state !== "pending" && task.periodStart && task.periodStart < state.snapshot.referenceDate) return "history";
  if (task.timeType === "someday") return "someday";
  if (task.timeType === "week") return "week";
  if (task.timeType === "month") return "month";
  if (task.periodStart === state.snapshot.referenceDate) return "today";
  if (task.periodStart > state.snapshot.referenceDate) return "tomorrow";
  return "today";
}

function visibleTasks() {
  const tasks = state.snapshot?.tasks || [];
  if (state.section === "history") return tasks.filter((task) => task.state !== "pending");
  if (state.section === "today") return tasks.filter((task) => task.timeType === "day" && (task.state === "pending" || task.periodStart === state.snapshot.referenceDate));
  if (state.section === "tomorrow") return tasks.filter((task) => task.periodStart > state.snapshot.referenceDate && task.state === "pending");
  if (state.section === "week") return tasks.filter((task) => task.timeType === "week" && task.state === "pending");
  if (state.section === "month") return tasks.filter((task) => task.timeType === "month" && task.state === "pending");
  if (state.section === "someday") return tasks.filter((task) => task.timeType === "someday" && task.state === "pending");
  return [];
}

function groupTasks(tasks) {
  const groups = new Map();
  for (const task of tasks) {
    const label = task.state !== "pending" ? "已完成" : task.periodStart === state.snapshot.referenceDate ? "今日" : "待处理";
    if (!groups.has(label)) groups.set(label, []);
    groups.get(label).push(task);
  }
  return [...groups.entries()];
}

function formatDate(value) {
  if (!value) return "";
  const date = new Date(`${value}T00:00:00`);
  return new Intl.DateTimeFormat("zh-CN", { month: "short", day: "numeric" }).format(date);
}

function questLabel(value) {
  return ({ main: "主线", side: "支线", extra: "外传" })[value] || value;
}

function taskRow(task, compact = false) {
  const settled = task.state !== "pending";
  const badgeClass = `badge badge-${task.questLine}`;
  return `<article class="task-row ${settled ? "is-settled" : ""} ${compact ? "is-compact" : ""}" data-task-id="${escapeHtml(task.id)}">
    <button class="check-button ${task.state === "completed" ? "is-checked" : ""}" data-action="toggle" data-id="${escapeHtml(task.id)}" aria-label="${task.state === "completed" ? "撤销完成" : "标记完成"}" title="${task.state === "completed" ? "撤销完成" : "标记完成"}" ${task.state === "pass" ? "disabled" : ""}>${task.state === "completed" ? icon("check", 16) : ""}</button>
    <div class="task-copy"><div class="task-title">${escapeHtml(task.title)}</div>
      <div class="task-meta"><span class="${badgeClass}">${questLabel(task.questLine)}</span><span>${escapeHtml(task.periodLabel || formatDate(task.periodStart))}</span>${task.recurrence === "repeat" ? `<span>${icon("repeat", 12)}</span>` : ""}${task.deadlineDate ? `<span class="deadline">${icon("calendar-clock", 12)} ${formatDate(task.deadlineDate)}</span>` : ""}</div>
    </div>
    ${!compact && !settled ? `<div class="row-actions"><button class="icon-button" data-action="move-up" data-id="${escapeHtml(task.id)}" aria-label="上移" title="上移">${icon("arrow-up", 15)}</button><button class="icon-button" data-action="move-down" data-id="${escapeHtml(task.id)}" aria-label="下移" title="下移">${icon("arrow-down", 15)}</button><button class="icon-button" data-action="edit" data-id="${escapeHtml(task.id)}" aria-label="编辑任务" title="编辑任务">${icon("pencil", 15)}</button><button class="icon-button" data-action="pass" data-id="${escapeHtml(task.id)}" aria-label="Pass" title="Pass">${icon("skip-forward", 15)}</button><button class="icon-button danger" data-action="delete" data-id="${escapeHtml(task.id)}" aria-label="删除任务" title="删除任务">${icon("trash-2", 15)}</button></div>` : ""}
  </article>`;
}

function titleForSection() {
  return ({ today: "今日与已规划的每日任务", tomorrow: "明日任务", week: "本周与已规划的每周任务", month: "本月与已规划的每月任务", someday: "没有截止时间的闲时任务", history: "历史记录", statistics: "统计" })[state.section] || "显示设置";
}

function titlebar() {
  return `<header class="titlebar" data-tauri-drag-region><div class="titlebar-brand">${icon("check-check", 18)}<span>Woo Todo</span></div><div class="titlebar-spacer"></div><button class="icon-button" data-action="toggle-board" aria-label="显示悬浮任务板" title="显示悬浮任务板">${icon("panel-right", 18)}</button><button class="icon-button" data-action="refresh" aria-label="刷新" title="刷新">${icon("refresh-cw", 18)}</button><button class="icon-button primary-icon" data-action="new-task" aria-label="新增任务" title="新增任务">${icon("plus", 18)}</button><div class="window-controls"><button data-window="minimize" aria-label="最小化" title="最小化">${icon("minus", 16)}</button><button data-window="maximize" aria-label="最大化" title="最大化">${icon("square", 14)}</button><button class="window-close" data-window="close" aria-label="关闭" title="关闭">${icon("x", 17)}</button></div></header>`;
}

function sidebar() {
  return `<aside class="sidebar"><div class="sidebar-heading">${icon("layers-3", 16)}<span>工作空间</span></div>${navGroups.map((group) => `<div class="nav-group"><div class="nav-label">${group.label}</div>${group.items.map(([id, label, symbol]) => `<button class="nav-item ${state.section === id ? "is-active" : ""}" data-section="${id}">${icon(symbol, 17)}<span>${label}</span>${id === "today" && pendingTodayCount() ? `<span class="nav-count">${pendingTodayCount()}</span>` : ""}</button>`).join("")}</div>`).join("")}<div class="sidebar-footer"><div class="sync-dot ${state.snapshot?.sync?.running ? "is-syncing" : ""}"></div><div><strong>${state.snapshot?.sync?.configuredMode ? "同步已连接" : "本地模式"}</strong><small>${state.snapshot?.sync?.lastError || "数据保存在此设备"}</small></div></div></aside>`;
}

function pendingTodayCount() {
  return (state.snapshot?.tasks || []).filter((task) => task.timeType === "day" && task.periodStart === state.snapshot.referenceDate && task.state === "pending").length;
}

function progressSummary(tasks) {
  const total = tasks.length;
  const completed = tasks.filter((task) => task.state === "completed").length;
  const progress = total ? Math.round((completed / total) * 100) : 0;
  return { total, completed, progress };
}

function toolbar() {
  return `<div class="page-toolbar"><div class="toolbar-status">${state.snapshot.header ? `<span class="eyebrow">${escapeHtml(state.snapshot.header)}</span>` : ""}<span class="toolbar-date">${formatDate(state.snapshot.referenceDate)}</span></div><div class="toolbar-actions"><button class="button secondary" data-action="toggle-board">${icon("panel-right", 15)}<span>悬浮任务板</span></button><button class="button primary" data-action="new-task">${icon("plus", 15)}<span>新增任务</span></button></div></div>`;
}

function taskPage() {
  const tasks = visibleTasks();
  const { total, completed, progress } = progressSummary(tasks);
  return `<section class="page task-page">${toolbar()}<div class="page-heading"><div><h1>${titleForSection()}</h1><p>${state.snapshot.subtitle ? escapeHtml(state.snapshot.subtitle) : "专注当下，把下一件事做完。"}</p></div><div class="progress-chip"><div class="progress-ring" style="--progress:${progress * 3.6}deg"><span>${progress}%</span></div><div><strong>${completed} / ${total}</strong><small>今日进度</small></div></div></div><div class="task-groups">${tasks.length ? groupTasks(tasks).map(([label, group]) => `<section class="task-group"><div class="group-heading"><span>${label}</span><span>${group.length}</span></div>${group.map((task) => taskRow(task)).join("")}</section>`).join("") : `<div class="empty-state">${icon("check-circle-2", 30)}<strong>暂无任务</strong><span>点击右上角加号创建下一件事。</span><button class="button primary" data-action="new-task">${icon("plus", 15)}<span>新增任务</span></button></div>`}</div></section>`;
}

function statisticsPage() {
  const stats = state.snapshot.statistics || {};
  const ended = stats.endedPeriods || { completed: 0, pass: 0 };
  const entries = Object.entries(stats.byTimeType || {});
  return `<section class="page"><div class="page-heading compact-heading"><div><span class="eyebrow">OVERVIEW</span><h1>统计</h1><p>把完成情况变成下一步行动。</p></div></div><div class="metric-grid"><div class="metric"><span>已完成周期</span><strong>${ended.completed}</strong><small>已结束周期</small></div><div class="metric"><span>已 Pass</span><strong>${ended.pass}</strong><small>需要重新安排</small></div><div class="metric"><span>今日待办</span><strong>${pendingTodayCount()}</strong><small>保持节奏</small></div></div><div class="section-panel"><div class="section-panel-title"><h2>按时间范围</h2><span>全部任务</span></div>${entries.map(([key, count]) => `<div class="stat-row"><span>${({ day: "每日", week: "每周", month: "每月", someday: "闲时" })[key] || key}</span><div class="stat-bar"><i style="width:${Math.min(100, ((count.pending || 0) + (count.completed || 0)) * 12)}%"></i></div><strong>${(count.pending || 0) + (count.completed || 0)}</strong></div>`).join("")}</div></section>`;
}

function syncPage() {
  const sync = state.snapshot.sync || {};
  const local = state.snapshot.localSync || {};
  const pairing = local.pairing || null;
  const modeNames = { worker: "自建服务", localNetwork: "同一网络", webDav: "WebDAV" };
  const configuredLabel = modeNames[sync.configuredMode] || sync.configuredMode || null;
  const pairingStatusHint = {
    open: "等待设备粘贴链接加入…",
    claimed: "",
    confirmed: "设备已加入同步空间",
    expired: "链接已过期，请重新生成",
    failed: "配对会话已失效，请重新生成",
  }[pairing?.status];
  const hostBody = local.enabled
    ? `<div class="host-meta"><span>服务地址 <code>${escapeHtml(local.endpoint || "")}</code></span><span>同步空间 <code>${escapeHtml(local.vaultId || "")}</code></span></div>`
      + (pairing
        ? `<div class="pairing-box">
            <label class="field-label">配对链接（10 分钟内有效，含同步密钥，请勿外传）</label>
            <div class="pairing-link-row"><input id="pairing-link-output" type="text" readonly spellcheck="false" value="${escapeHtml(pairing.link)}" /><button class="button secondary" data-action="copy-pairing-link">${icon("copy", 14)}<span>复制</span></button></div>
            ${pairing.status === "claimed" && pairing.claimedDevice
              ? `<div class="pairing-claim"><div>${icon("smartphone", 16)}<span><strong>${escapeHtml(pairing.claimedDevice.name)}</strong><small>${escapeHtml(pairing.claimedDevice.platform)} 请求加入此同步空间</small></span></div><div class="pairing-claim-actions"><button class="button secondary" data-action="deny-pairing">拒绝</button><button class="button primary" data-action="accept-pairing">${icon("check", 14)}<span>允许加入</span></button></div></div>`
              : `<span class="hint">${escapeHtml(pairingStatusHint || "")}</span>`}
          </div>`
        : `<div class="host-start-row"><button class="button primary" data-action="create-local-pairing">${icon("link", 15)}<span>生成配对链接</span></button><span class="hint">生成后需在 10 分钟内由 Android 完成加入</span></div>`)
      + `<button class="button ghost host-stop" data-action="stop-local-sync">停止局域网同步服务</button>`
    : `<div class="host-start-row"><button class="button primary" data-action="start-local-sync">${icon("wifi", 15)}<span>开启局域网同步服务</span></button><span class="hint">Windows 成为同一网络的同步主机，Android 粘贴配对链接即可加入；仅当 Windows 尚未加入任何同步空间时可用</span></div>`;
  return `<section class="page"><div class="page-heading compact-heading"><div><span class="eyebrow">CONNECTION</span><h1>同步</h1><p>在 Windows、Mac 和 Android 之间使用同一份数据，任务始终先保存在本机。同步空间可以从任一已有同步设备（Mac、Windows）或自建 HTTPS 服务生成配对链接；跨网络场景请使用自建服务或第三方 WebDAV。</p></div><button class="button secondary" data-action="sync">${icon("refresh-cw", 15)}<span>立即同步</span></button></div><div class="section-panel sync-panel"><div class="sync-state"><div class="sync-mark">${icon(sync.configuredMode ? "cloud" : "hard-drive", 20)}</div><div><strong>${configuredLabel ? "同步服务已配置" : "尚未配置同步"}</strong><span>${configuredLabel ? `方式：${configuredLabel}` : "任务仍会安全保存在本机"}</span></div><span class="status-pill ${sync.running ? "is-busy" : ""}">${sync.running ? "同步中" : "就绪"}</span></div></div><div class="section-panel sync-panel"><div class="section-panel-title"><h2>加入已有同步空间</h2><span>粘贴其他设备生成的配对链接</span></div><div class="sync-join"><label class="field-label">配对链接<input id="pairing-link-input" type="url" spellcheck="false" autocomplete="off" placeholder="粘贴 wootodo://pair 链接" /></label><label class="toggle-row dialog-toggle"><span><strong>替换当前 Windows 同步身份</strong><small>加入后以同步空间数据为准：本地任务会从 Windows 移除且不会上传，同步空间的数据会完整下载；不同同步空间会被拒绝。</small></span><input id="pairing-replace-input" type="checkbox" /><i></i></label><button class="button primary" data-action="join-sync">${icon("link", 15)}<span>加入同步空间</span></button></div></div><div class="section-panel sync-panel"><div class="section-panel-title"><h2>同一网络主机</h2><span>Windows 生成配对链接，Android 加入</span></div><div class="sync-join">${hostBody}</div></div><div class="settings-note">加入已有同步空间时，始终以同步空间的数据为准：Windows 本地任务会被移除（不会上传，不影响其他设备），同步空间的任务会完整同步到 Windows，避免用空白或测试数据覆盖真实数据。同一网络：让 Windows 或 Mac 在同一网络下开启同步服务，手机扫码或粘贴链接加入，适合设备经常同网；跨网络（例如 Mac 与 Windows 不在同一网络）时请改用自建 HTTPS 服务或第三方 WebDAV，两者都可以让 Mac、Windows、Android 三端互相同步。三种方式互斥；切换会保留本地任务并从新的同步空间重新同步。</div></div></section>`;
}

function settingsPage() {
  if (state.section === "sync") return syncPage();
  if (state.section === "shortcuts") {
    const shortcuts = state.snapshot.shortcuts || [];
    return `<section class="page"><div class="page-heading compact-heading"><div><span class="eyebrow">COMMANDS</span><h1>快捷键</h1><p>让常用操作保持在手边。</p></div></div><div class="section-panel shortcut-list">${shortcuts.map(({ label, display, icon: symbol }) => `<div class="shortcut-row">${icon(symbol, 17)}<span>${escapeHtml(label)}</span><kbd aria-label="${escapeHtml(display)}">${escapeHtml(display)}</kbd></div>`).join("")}</div></section>`;
  }
  const board = state.snapshot.board;
  const dc = state.snapshot.displayConfig || { headerTemplate: "", subtitleTemplate: "", startDate: "", deadlineDate: "" };
  const displayTokens = [
    ["星期几", "{weekday}"], ["星期简写", "{weekdayShort}"], ["英文星期", "{weekdayEn}"], ["英文简写", "{weekdayEnShort}"],
    ["日期", "{date}"], ["中文日期", "{dateLong}"], ["年份", "{year}"], ["月份", "{month}"], ["两位月份", "{monthPadded}"], ["日", "{day}"], ["两位日", "{dayPadded}"],
    ["开始日期", "{startDate}"], ["截止日期", "{deadlineDate}"],
    ["已过天数", "{elapsedDays}"], ["距截止天数", "{deadlineDays}"], ["已过月天", "{elapsedMonthsDays}"], ["距截止月天", "{deadlineMonthsDays}"],
  ];
  return `<section class="page"><div class="page-heading compact-heading"><div><span class="eyebrow">APPEARANCE</span><h1>显示</h1><p>调整悬浮任务板的存在感和交互方式。</p></div><button class="button primary" data-action="save-board">${icon("check", 15)}<span>应用设置</span></button></div><div class="section-panel settings-form"><div class="section-panel-title"><h2>今日标题与副标题</h2><span>模板变量插入光标处，随任务一起同步到其他设备</span></div><label class="field-label">标题模板<input id="header-template-input" maxlength="80" spellcheck="false" value="${escapeHtml(dc.headerTemplate || "")}" /></label><label class="field-label">副标题模板<input id="subtitle-template-input" maxlength="160" spellcheck="false" placeholder="如：DDL · {deadlineMonthsDays}" value="${escapeHtml(dc.subtitleTemplate || "")}" /></label><div class="token-row">${displayTokens.map(([label, token]) => `<button type="button" class="token-chip" data-insert-token="${token}">${label}</button>`).join("")}</div><div class="field-grid"><label class="field-label">开始日期（已过天数基准）<input id="display-start-date" type="date" value="${escapeHtml(dc.startDate || "")}" /></label><label class="field-label">截止日期（距截止天数基准）<input id="display-deadline-date" type="date" value="${escapeHtml(dc.deadlineDate || "")}" /></label></div><button class="button primary" data-action="save-display">${icon("check", 15)}<span>应用标题设置</span></button></div><div class="section-panel settings-form"><label class="range-label"><span>不透明度</span><strong id="opacity-value">${board.opacityPercent}%</strong></label><input id="opacity-input" type="range" min="20" max="100" step="10" value="${board.opacityPercent}" /><label class="toggle-row"><span><strong>任务板始终置顶</strong><small>保持在其他窗口上方</small></span><input id="topmost-input" type="checkbox" ${board.alwaysOnTop ? "checked" : ""} /><i></i></label><label class="toggle-row"><span><strong>鼠标穿透</strong><small>显示内容但不拦截桌面操作</small></span><input id="through-input" type="checkbox" ${board.clickThrough ? "checked" : ""} /><i></i></label><label class="toggle-row"><span><strong>桌面小组件模式</strong><small>保持在普通窗口底层</small></span><input id="widget-input" type="checkbox" ${board.desktopWidget ? "checked" : ""} /><i></i></label></div></section>`;
}

function mainView() {
  const content = state.section === "statistics" ? statisticsPage() : ["display", "shortcuts", "sync"].includes(state.section) ? settingsPage() : taskPage();
  const editing = state.snapshot.tasks.find((task) => task.id === state.editingTaskId);
  const timeOptions = [["day", "每日"], ["week", "每周"], ["month", "每月"], ["someday", "闲时"]]
    .map(([value, label]) => `<option value="${value}" ${editing?.timeType === value ? "selected" : ""}>${label}</option>`).join("");
  const questOptions = [["main", "主线"], ["side", "支线"], ["extra", "外传"]]
    .map(([value, label]) => `<option value="${value}" ${editing?.questLine === value ? "selected" : ""}>${label}</option>`).join("");
  return `<div class="window-shell">${titlebar()}<div class="workspace">${sidebar()}<main class="main-content">${state.error ? `<div class="error-banner">${icon("triangle-alert", 16)}<span>${escapeHtml(state.error)}</span></div>` : ""}${content}</main></div></div><dialog id="task-dialog"><form method="dialog" id="task-form"><div class="dialog-heading"><div><span class="eyebrow">${editing ? "EDIT TASK" : "NEW TASK"}</span><h2>${editing ? "编辑任务" : "新增任务"}</h2></div><button class="icon-button" type="button" data-close-dialog aria-label="关闭">${icon("x", 18)}</button></div><label class="field-label">任务内容<input name="title" required maxlength="120" autofocus placeholder="下一件要完成的事" value="${escapeHtml(editing?.title || "")}" /></label><div class="field-grid"><label class="field-label">时间范围<select name="timeType">${timeOptions}</select></label><label class="field-label">级别<select name="questLine">${questOptions}</select></label></div><label class="field-label">目标日期<input name="targetDate" type="date" value="${editing?.periodStart || state.snapshot.referenceDate}" required /></label><label class="toggle-row dialog-toggle"><span><strong>重复任务</strong><small>在同一时间范围继续出现</small></span><input name="repeats" type="checkbox" ${editing?.recurrence === "repeat" ? "checked" : ""} /><i></i></label><div class="dialog-actions"><button class="button secondary" type="button" data-close-dialog>取消</button><button class="button primary" value="default" type="submit">${icon(editing ? "check" : "plus", 15)}<span>${editing ? "保存" : "创建任务"}</span></button></div></form></dialog>`;
}

function boardView() {
  const tasks = (state.snapshot?.tasks || []).filter((task) => task.timeType === "day" && task.state === "pending");
  const total = (state.snapshot?.tasks || []).filter((task) => task.timeType === "day").length;
  const completed = total - tasks.length;
  const widget = Boolean(state.snapshot?.board?.desktopWidget);
  // 滑块控制背景透明程度；文字始终完全不透明，保证可读。
  // 小组件模式背景整体更实，避免被桌面内容干扰。
  const percent = Math.max(20, Math.min(100, state.snapshot?.board?.opacityPercent || 100));
  const alpha = widget ? 0.55 + 0.45 * (percent / 100) : 0.3 + 0.6 * (percent / 100);
  const gradient = `linear-gradient(150deg, rgba(48,58,62,${alpha}) 0%, rgba(25,31,34,${(alpha * 0.92).toFixed(3)}) 55%, rgba(18,23,26,${alpha}) 100%)`;
  return `<div class="board-window"><div class="board-content${widget ? " is-widget" : ""}" data-tauri-drag-region="deep" style="background:${gradient}"><header class="board-header"><div><h1>${escapeHtml(state.snapshot?.header || "今日任务")}</h1><p>${escapeHtml(state.snapshot?.subtitle || "")}</p></div><div class="board-date"><strong>${escapeHtml(state.snapshot?.lunarDate || "")}</strong><span>${escapeHtml(state.snapshot?.lunarAnnotation || "")}</span></div></header><div class="board-progress"><div><span>今日进度</span><strong>${completed} / ${total}</strong></div><div class="progress-line"><i style="width:${total ? (completed / total) * 100 : 0}%"></i></div></div><div class="board-list" data-tauri-drag-region="false">${tasks.length ? tasks.map((task) => taskRow(task, true)).join("") : `<div class="board-empty">${icon("check-circle-2", 25)}<span>今天暂时没有待办</span></div>`}</div></div></div>`;
}

function render() {
  if (!state.snapshot) {
    app.innerHTML = `<div class="loading-screen">${icon("loader-circle", 24)}<span>正在打开 Woo Todo</span></div>`;
    refreshIcons();
    return;
  }
  app.innerHTML = view === "board" ? boardView() : mainView();
  refreshIcons();
  bindEvents();
  bindAppEvents();
}

function bindEvents() {
  document.querySelectorAll("[data-section]").forEach((button) => button.addEventListener("click", () => { state.section = button.dataset.section; render(); }));
  document.querySelectorAll("[data-window]").forEach((button) => button.addEventListener("click", () => callWindow(button.dataset.window)));
  document.querySelectorAll("[data-action]").forEach((button) => button.addEventListener("click", () => handleAction(button.dataset.action, button.dataset.id)));
  document.querySelectorAll("#header-template-input, #subtitle-template-input").forEach((input) => input.addEventListener("focus", () => { state.lastTemplateField = input.id; }));
  document.querySelectorAll("[data-insert-token]").forEach((button) => button.addEventListener("click", () => {
    const target = document.querySelector(state.lastTemplateField === "subtitle-template-input" ? "#subtitle-template-input" : "#header-template-input");
    if (!target) return;
    const token = button.dataset.insertToken || "";
    const start = target.selectionStart ?? target.value.length;
    const end = target.selectionEnd ?? target.value.length;
    target.value = target.value.slice(0, start) + token + target.value.slice(end);
    target.focus();
    target.setSelectionRange(start + token.length, start + token.length);
  }));
  const form = document.querySelector("#task-form");
  if (form) form.addEventListener("submit", submitTask);
  document.querySelectorAll("[data-close-dialog]").forEach((button) => button.addEventListener("click", () => document.querySelector("#task-dialog")?.close()));
  const opacity = document.querySelector("#opacity-input");
  if (opacity) opacity.addEventListener("input", () => { document.querySelector("#opacity-value").textContent = `${opacity.value}%`; });
}

async function callWindow(action) {
  if (!isTauri) return;
  await invokeCommand("window_action", { action });
}

async function handleAction(action, id) {
  if (state.busy) return;
  if (action === "new-task") { openTaskDialog(null); return; }
  if (action === "refresh") { await loadSnapshot(); return; }
  if (action === "toggle-board") { if (isTauri) await invokeCommand("toggle_board"); return; }
  if (action === "open-main") { if (isTauri) await invokeCommand("show_main"); return; }
  if (action === "sync") { await runCommand("request_sync"); return; }
  if (action === "join-sync") { await joinSyncSpace(); return; }
  if (action === "start-local-sync") { await runCommand("start_local_sync"); return; }
  if (action === "stop-local-sync") { if (window.confirm("停止局域网同步服务？已加入的 Android 设备将无法继续通过 Windows 同步。")) await runCommand("stop_local_sync"); return; }
  if (action === "create-local-pairing") { await runCommand("create_local_pairing"); return; }
  if (action === "accept-pairing") { await runCommand("respond_local_pairing", { accept: true }); return; }
  if (action === "deny-pairing") { await runCommand("respond_local_pairing", { accept: false }); return; }
  if (action === "copy-pairing-link") { const value = document.querySelector("#pairing-link-output")?.value; if (value && isTauri) navigator.clipboard?.writeText(value).then(() => { state.error = "配对链接已复制"; render(); }).catch(() => { state.error = "复制失败，请手动选择链接复制"; render(); }); return; }
  if (action === "edit" && id) { openTaskDialog(state.snapshot.tasks.find((task) => task.id === id)); return; }
  if (action === "move-up" && id) { await runCommand("move_task", { id, offset: -1 }); return; }
  if (action === "move-down" && id) { await runCommand("move_task", { id, offset: 1 }); return; }
  if (action === "delete" && id && !window.confirm("删除这条任务？")) return;
  if (["toggle", "pass", "delete"].includes(action) && id) await runCommand(`${action}_task`, { id });
  if (action === "save-board") await saveBoardPreferences();
  if (action === "save-display") {
    try {
      await runCommand("save_display_configuration", {
        input: {
          headerTemplate: document.querySelector("#header-template-input")?.value || "",
          subtitleTemplate: document.querySelector("#subtitle-template-input")?.value || "",
          startDate: document.querySelector("#display-start-date")?.value || state.snapshot.displayConfig?.startDate || state.snapshot.referenceDate,
          deadlineDate: document.querySelector("#display-deadline-date")?.value || state.snapshot.displayConfig?.deadlineDate || state.snapshot.referenceDate,
        },
      });
      notify("标题设置已应用");
    } catch (error) {
      notify(`应用失败：${error?.message || error}`);
    }
    return;
  }
}

async function runCommand(command, payload) {
  state.busy = true;
  try { state.snapshot = await invokeCommand(command, payload); state.error = ""; render(); }
  catch (error) { state.error = String(error); render(); }
  finally { state.busy = false; }
}

async function submitTask(event) {
  event.preventDefault();
  const data = new FormData(event.currentTarget);
  const input = { title: data.get("title"), timeType: data.get("timeType"), targetDate: data.get("targetDate"), questLine: data.get("questLine"), repeats: data.get("repeats") === "on", reminderTime: null, deadlineDate: null };
  const command = state.editingTaskId ? "update_task" : "create_task";
  if (state.editingTaskId) input.id = state.editingTaskId;
  state.editingTaskId = null;
  await runCommand(command, { input });
}

function openTaskDialog(task) {
  state.editingTaskId = task?.id || null;
  render();
  document.querySelector("#task-dialog")?.showModal();
}

let toastTimer = null;
function notify(message) {
  let toast = document.querySelector("#app-toast");
  if (!toast) {
    toast = document.createElement("div");
    toast.id = "app-toast";
    document.body.appendChild(toast);
  }
  toast.textContent = message;
  toast.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("show"), 2200);
}

async function saveBoardPreferences() {
  try {
    await runCommand("save_board_preferences", { input: { opacityPercent: Number(document.querySelector("#opacity-input")?.value || 100), alwaysOnTop: Boolean(document.querySelector("#topmost-input")?.checked), clickThrough: Boolean(document.querySelector("#through-input")?.checked), desktopWidget: Boolean(document.querySelector("#widget-input")?.checked) } });
    notify("显示设置已应用");
  } catch (error) {
    notify(`应用失败：${error?.message || error}`);
  }
}

async function joinSyncSpace() {
  const pairingLink = document.querySelector("#pairing-link-input")?.value.trim();
  if (!pairingLink) {
    state.error = "请粘贴已有同步空间生成的配对链接。";
    render();
    return;
  }
  const replace = Boolean(document.querySelector("#pairing-replace-input")?.checked);
  if (state.snapshot.sync.configuredMode && !replace) {
    state.error = "当前已有同步身份。请勾选替换当前身份后再次加入；本地任务不会被删除。";
    render();
    return;
  }
  const localCount = state.snapshot.tasks?.length || 0;
  let clearLocalTasks = false;
  if (localCount > 0) {
    clearLocalTasks = window.confirm(`Windows 本地现有 ${localCount} 条任务。\n\n加入已有同步空间后将以同步空间的数据为准：\n· 同步空间的任务会完整同步到 Windows；\n· 本地这 ${localCount} 条任务会从 Windows 移除，不会上传，不影响其他设备。\n\n如果这些本地任务仍需保留，请选择「取消」并先处理它们。`);
    if (!clearLocalTasks) return;
  }
  if (replace && !window.confirm("确认加入此配对链接？当前 Windows 同步身份会被替换；不同同步空间会被拒绝。")) return;
  await runCommand("join_sync_space", { input: { pairingLink, confirmReplace: replace, clearLocalTasks } });
}

loadSnapshot();
