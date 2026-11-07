try {
  const theme = sessionStorage.getItem("agent-talk-theme");
  if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
} catch {}
