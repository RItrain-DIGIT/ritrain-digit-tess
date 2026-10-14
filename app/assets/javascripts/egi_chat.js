(function () {
  function initializeEgiChat() {
    const toggleBtn = document.getElementById("egi-chat-toggle");
    const closeBtn = document.getElementById("egi-chat-close");
    const chatWindow = document.getElementById("egi-chat-window");
    const sendBtn = document.getElementById("egi-chat-send");
    const inputField = document.getElementById("egi-chat-input");
    const messagesContainer = document.getElementById("egi-chat-messages");

    // Widget is not present on this page.
    if (
      !toggleBtn ||
      !closeBtn ||
      !chatWindow ||
      !sendBtn ||
      !inputField ||
      !messagesContainer
    ) {
      return;
    }

    // Prevent duplicate event handlers when Turbolinks loads the page.
    if (toggleBtn.dataset.egiChatInitialized === "true") {
      return;
    }

    toggleBtn.dataset.egiChatInitialized = "true";

    console.log("EGI Chat: initialized");

    let conversationHistory = [];

    // Open / close chat window
    toggleBtn.addEventListener("click", function (event) {
      event.preventDefault();

      chatWindow.classList.toggle("hidden");

      if (!chatWindow.classList.contains("hidden")) {
        inputField.focus();
      }
    });

    // Close button
    closeBtn.addEventListener("click", function (event) {
      event.preventDefault();

      chatWindow.classList.add("hidden");
    });

    // Send message
    async function sendMessage() {
      const text = inputField.value.trim();

      if (!text) {
        return;
      }

      appendMessage("user", text);

      conversationHistory.push({
        role: "user",
        content: text
      });

      inputField.value = "";
      sendBtn.disabled = true;

      const csrfToken = document
        .querySelector('meta[name="csrf-token"]')
        ?.getAttribute("content");

      try {
        const response = await fetch("/api/v1/llm/chat", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken
          },
          body: JSON.stringify({
            messages: conversationHistory
          })
        });

        if (!response.ok) {
          throw new Error(
            `Request failed with status ${response.status}`
          );
        }

        const data = await response.json();

        const reply =
          data?.choices?.[0]?.message?.content ||
          "Sorry, I couldn't generate a response.";

        appendMessage("assistant", reply);

        conversationHistory.push({
          role: "assistant",
          content: reply
        });
      } catch (error) {
        console.error("EGI Chat Error:", error);

        appendMessage(
          "assistant",
          "Sorry, an error occurred communicating with EGI AI."
        );
      } finally {
        sendBtn.disabled = false;
        inputField.focus();
      }
    }

    // Add message to transcript
    function appendMessage(role, text) {
      const msgDiv = document.createElement("div");

      msgDiv.classList.add("chat-msg", role);
      msgDiv.textContent = text;

      messagesContainer.appendChild(msgDiv);
      messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }

    // Send button
    sendBtn.addEventListener("click", function (event) {
      event.preventDefault();
      sendMessage();
    });

    // Enter key
    inputField.addEventListener("keydown", function (event) {
      if (event.key === "Enter") {
        event.preventDefault();
        sendMessage();
      }
    });
  }

  // Normal page load
  document.addEventListener("DOMContentLoaded", initializeEgiChat);

  // Turbolinks page navigation
  document.addEventListener("turbolinks:load", initializeEgiChat);
})();
