import { Socket } from "/assets/phoenix/phoenix.mjs";
import { LiveSocket } from "/assets/liveview/phoenix_live_view.esm.js";

const Hooks = {
  ConnectionStatus: {
    mounted() { this.setStatus("connected", "Connected"); },
    disconnected() { this.setStatus("disconnected", "Reconnecting"); },
    reconnected() { this.setStatus("connected", "Connected"); },
    setStatus(state, label) {
      this.el.classList.remove("is-connecting", "is-connected", "is-disconnected");
      this.el.classList.add(`is-${state}`);
      this.el.querySelector("[data-connection-label]").textContent = label;
    },
  },
};

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: document.querySelector('meta[name="csrf-token"]').content },
  hooks: Hooks,
});
liveSocket.connect();

document.addEventListener("click", (event) => {
  if (!event.target.closest("#theme-toggle")) return;
  const root = document.documentElement;
  const current = root.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  const next = current === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try { sessionStorage.setItem("agent-talk-theme", next); } catch {}
});
