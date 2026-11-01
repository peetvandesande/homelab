// Radio search card: free-text search over radio-browser.info, filtered by
// category (tag) and country, played on a chosen media_player.
//
//   type: custom:radio-search-card
//   country: NL          # optional default country code
//   entities: [...]      # optional, narrows the player picker
//   limit: 50            # optional, results per search
//
// Plain ES module with shadow DOM: no build step, nothing loaded from outside.

const FALLBACK_API = "https://de1.api.radio-browser.info";
const STORAGE_KEY = "radio-search-card.player";

function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function storageGet(key) {
  try { return window.localStorage.getItem(key); } catch (e) { return null; }
}

function storageSet(key, value) {
  try { window.localStorage.setItem(key, value); } catch (e) { /* private window */ }
}

let apiBase; // shared by every card on the page

async function pickApi() {
  if (apiBase) return apiBase;
  apiBase = (async () => {
    try {
      const r = await fetch("https://all.api.radio-browser.info/json/servers");
      const servers = await r.json();
      const names = [...new Set(servers.map((s) => s.name))];
      if (names.length) return `https://${names[Math.floor(Math.random() * names.length)]}`;
    } catch (e) { /* fall through */ }
    return FALLBACK_API;
  })();
  return apiBase;
}

async function api(path, params = {}) {
  const base = await pickApi();
  const qs = new URLSearchParams(
    Object.entries(params).filter(([, v]) => v !== "" && v !== undefined && v !== null),
  );
  const r = await fetch(`${base}/json/${path}?${qs}`);
  if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
  return r.json();
}

class RadioSearchCard extends HTMLElement {
  setConfig(config) {
    if (config.entities && !Array.isArray(config.entities)) {
      throw new Error("entities must be a list of media_player entity ids");
    }
    if (config.limit !== undefined && !(Number(config.limit) > 0)) {
      throw new Error("limit must be a positive number");
    }
    this._config = { limit: 50, ...config };
    if (this._root) this._renderPlayers();
  }

  set hass(hass) {
    const first = !this._hass;
    this._hass = hass;
    if (!this._root) this._build();
    this._renderPlayers();
    if (first) this._loadFilters();
  }

  getCardSize() {
    return 8;
  }

  static getStubConfig() {
    return { country: "" };
  }

  _build() {
    this._root = this.attachShadow({ mode: "open" });
    this._root.innerHTML = `
      <style>
        :host { display: block; }
        ha-card { padding: 16px; }
        .filters { display: grid; gap: 8px; grid-template-columns: 1fr 1fr; }
        .filters .wide { grid-column: 1 / -1; }
        input, select {
          box-sizing: border-box; width: 100%; padding: 8px; font: inherit;
          color: var(--primary-text-color); background: var(--card-background-color);
          border: 1px solid var(--divider-color); border-radius: 6px;
        }
        label { font-size: 0.8em; color: var(--secondary-text-color); display: block; margin-bottom: 2px; }
        .status { margin: 12px 0 4px; font-size: 0.9em; color: var(--secondary-text-color); }
        .status.error { color: var(--error-color); }
        ul { list-style: none; margin: 0; padding: 0; max-height: 480px; overflow-y: auto; }
        li { display: flex; align-items: center; gap: 10px; padding: 6px 0;
             border-bottom: 1px solid var(--divider-color); }
        li img, li .noicon { width: 40px; height: 40px; border-radius: 4px; flex: none;
             object-fit: contain; background: var(--secondary-background-color); }
        .meta { flex: 1; min-width: 0; }
        .name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .sub { font-size: 0.8em; color: var(--secondary-text-color);
               overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        button { flex: none; cursor: pointer; border: none; border-radius: 50%; width: 36px; height: 36px;
                 background: var(--primary-color); color: var(--text-primary-color, #fff); font-size: 16px; }
        button:disabled { opacity: 0.4; cursor: default; }
        @media (max-width: 450px) { .filters { grid-template-columns: 1fr; } }
      </style>
      <ha-card header="${escapeHtml(this._config?.title ?? "Radio")}">
        <div class="filters">
          <div class="wide"><label>Search</label>
            <input id="q" type="search" placeholder="Station name"></div>
          <div><label>Category</label>
            <input id="tag" list="tags" placeholder="Any"><datalist id="tags"></datalist></div>
          <div><label>Country</label>
            <select id="country"><option value="">Any</option></select></div>
          <div class="wide"><label>Play on</label><select id="player"></select></div>
        </div>
        <div class="status" id="status"></div>
        <ul id="results"></ul>
      </ha-card>`;

    const $ = (id) => this._root.getElementById(id);
    this._q = $("q");
    this._tag = $("tag");
    this._tags = $("tags");
    this._country = $("country");
    this._player = $("player");
    this._status = $("status");
    this._results = $("results");

    const schedule = () => {
      clearTimeout(this._timer);
      this._timer = setTimeout(() => this._search(), 300);
    };
    this._q.addEventListener("input", schedule);
    this._tag.addEventListener("input", schedule);
    this._country.addEventListener("change", schedule);
    this._player.addEventListener("change", () => {
      storageSet(STORAGE_KEY, this._player.value);
      this._results.querySelectorAll("button").forEach((b) => { b.disabled = !this._player.value; });
    });
    this._results.addEventListener("click", (ev) => {
      const btn = ev.target.closest("button");
      if (btn) this._play(Number(btn.dataset.index));
    });
  }

  _renderPlayers() {
    if (!this._hass || !this._player) return;
    const wanted = this._config?.entities;
    const ids = Object.keys(this._hass.states)
      .filter((id) => id.startsWith("media_player.") && (!wanted || wanted.includes(id)))
      .sort((a, b) => this._friendly(a).localeCompare(this._friendly(b)));
    const key = ids.map((id) => `${id}:${this._hass.states[id].state}`).join("|");
    if (key === this._playersKey) return; // hass updates often; only redraw on change
    this._playersKey = key;

    const current = this._player.value || storageGet(STORAGE_KEY) || "";
    this._player.innerHTML = ids.length
      ? ids.map((id) => {
          const off = this._hass.states[id].state === "unavailable";
          return `<option value="${escapeHtml(id)}"${off ? " disabled" : ""}>${escapeHtml(this._friendly(id))}${off ? " (unavailable)" : ""}</option>`;
        }).join("")
      : `<option value="">No media players</option>`;
    if (ids.includes(current)) this._player.value = current;
  }

  _friendly(id) {
    return this._hass.states[id]?.attributes?.friendly_name || id;
  }

  async _loadFilters() {
    this._setStatus("Loading…");
    try {
      const [countries, tags] = await Promise.all([
        api("countries", { order: "stationcount", reverse: "true", hidebroken: "true" }),
        api("tags", { order: "stationcount", reverse: "true", hidebroken: "true", limit: 200 }),
      ]);
      const opts = countries
        .filter((c) => c.iso_3166_1)
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((c) => `<option value="${escapeHtml(c.iso_3166_1)}">${escapeHtml(c.name)} (${c.stationcount})</option>`);
      this._country.innerHTML = `<option value="">Any</option>${opts.join("")}`;
      const def = (this._config?.country || "").toUpperCase();
      if (def) this._country.value = def;
      this._tags.innerHTML = tags
        .map((t) => `<option value="${escapeHtml(t.name)}">${t.stationcount}</option>`)
        .join("");
    } catch (e) {
      this._setStatus(`Could not reach radio-browser.info: ${e.message}`, true);
      return;
    }
    this._search();
  }

  async _search() {
    const seq = (this._seq = (this._seq || 0) + 1);
    const params = {
      name: this._q.value.trim(),
      tag: this._tag.value.trim().toLowerCase(),
      countrycode: this._country.value,
      hidebroken: "true",
      order: "clickcount",
      reverse: "true",
      limit: this._config.limit,
    };
    this._setStatus("Searching…");
    let stations;
    try {
      stations = await api("stations/search", params);
    } catch (e) {
      if (seq === this._seq) this._setStatus(`Search failed: ${e.message}`, true);
      return;
    }
    if (seq !== this._seq) return; // a newer search has started
    this._stations = stations;
    this._setStatus(stations.length
      ? `${stations.length}${stations.length >= this._config.limit ? "+" : ""} stations`
      : "No stations match");
    const disabled = this._player.value ? "" : " disabled";
    this._results.innerHTML = stations.map((s, i) => {
      const icon = /^https:\/\//.test(s.favicon || "")
        ? `<img src="${escapeHtml(s.favicon)}" alt="" loading="lazy" referrerpolicy="no-referrer">`
        : `<div class="noicon"></div>`;
      const sub = [s.country, s.tags?.split(",").slice(0, 4).join(", "),
        s.codec && `${s.codec}${s.bitrate ? ` ${s.bitrate}k` : ""}`].filter(Boolean).join(" · ");
      return `<li>${icon}<div class="meta"><div class="name">${escapeHtml(s.name.trim())}</div>
        <div class="sub">${escapeHtml(sub)}</div></div>
        <button data-index="${i}" title="Play"${disabled}>▶</button></li>`;
    }).join("");
    this._results.querySelectorAll("img").forEach((img) => {
      img.addEventListener("error", () => { img.replaceWith(Object.assign(document.createElement("div"), { className: "noicon" })); }, { once: true });
    });
  }

  async _play(index) {
    const s = this._stations?.[index];
    const entity = this._player.value;
    if (!s || !entity) return;
    try {
      await this._hass.callService("media_player", "play_media", {
        entity_id: entity,
        media_content_id: s.url_resolved || s.url,
        media_content_type: "music",
      });
      this._setStatus(`Playing ${s.name.trim()} on ${this._friendly(entity)}`);
      // radio-browser.info asks clients to report plays; it feeds the ranking.
      pickApi().then((base) => fetch(`${base}/json/url/${encodeURIComponent(s.stationuuid)}`)).catch(() => {});
    } catch (e) {
      this._setStatus(`Could not play: ${e.message}`, true);
    }
  }

  _setStatus(text, error = false) {
    this._status.textContent = text;
    this._status.classList.toggle("error", error);
  }
}

customElements.define("radio-search-card", RadioSearchCard);
window.customCards = window.customCards || [];
window.customCards.push({
  type: "radio-search-card",
  name: "Radio search",
  description: "Search radio-browser.info by name, category and country, and play on a media player.",
});
