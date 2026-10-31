// Acceptance automation is opt-in; ordinary demo visits have no side effects.
if (new URLSearchParams(location.search).has("browser_probe")) {
  const wait = async (condition) => {
    for (let n = 0; n < 150; n++) {
      if (condition()) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error("Browser condition timed out");
  };
  window.addEventListener("load", async () => {
    try {
      await wait(() => document.querySelector("#greet"));
      await new Promise(resolve => setTimeout(resolve, 100));
      document.querySelector("#greet").click();
      await wait(() => document.querySelector("output").textContent.includes("Hello from Stimulus"));
      document.querySelector("input[name=title]").value = "Browser created";
      document.querySelector("form").requestSubmit();
      await wait(() => document.querySelector("#posts").textContent.includes("Browser created"));
      document.querySelector(".post a").click();
      await wait(() => document.querySelector("h1").textContent === "Edit post");
      document.querySelector("input[name=title]").value = "Browser updated";
      document.querySelector("form").requestSubmit();
      await wait(() => document.querySelector("#posts")?.textContent.includes("Browser updated"));
      document.querySelector(".post form").requestSubmit();
      await wait(() => !document.querySelector(".post"));
      document.body.dataset.browserResult = "passed";
    } catch (error) {
      document.body.dataset.browserResult = "failed";
      document.body.dataset.browserError = error.message;
    }
  }, { once: true });
}
