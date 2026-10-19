(function () {
  function initializeEgiChat() {
    const toggleBtn = document.getElementById("egi-chat-toggle");
    const closeBtn = document.getElementById("egi-chat-close");
    const clearBtn = document.getElementById("egi-chat-clear");
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
    console.log("EGI Chat: Initialized!");

    let conversationHistory = [];
    let isSending = false;

    // Open/Close chat window.
    toggleBtn.addEventListener("click", function (event) {
      event.preventDefault();
      chatWindow.classList.toggle("hidden");

      if (!chatWindow.classList.contains("hidden")) {
        inputField.focus();
      }
    });

    // Close button.
    closeBtn.addEventListener("click", function (event) {
      event.preventDefault();
      chatWindow.classList.add("hidden");
    });
   
    // Clear transcript and conversation history.
    if (clearBtn) {
      clearBtn.addEventListener("click", function (event) {
        console.log("EGI: Clean button fired!");
        event.preventDefault();

        // Avoid clearing the transcript while a request is in progress.
        if (isSending) return;

        messagesContainer.replaceChildren();
        conversationHistory = [];
        // Display the default greeting
        appendMessage("assistant", "Hello! How can I assist you today?");
        inputField.value = "";
        inputField.placeHolder = "Type a question...";
        inputField.focus();

        console.log("EGI Chat: Conversation cleared!");
      });
    }

    // Send message to the API.
    async function sendMessage() {
      const text = inputField.value.trim();

      if (!text || isSending) return;

      appendMessage("user", text);

      conversationHistory.push({
        role: "user",
        content: text
      });

      inputField.value = "";
      isSending = true;
      sendBtn.disabled = true;
      inputField.disabled = true;

      // Show a loading indicator.
      const loadingMessage = appendMessage("assistant", "Thinking...");

      const csrfToken = document
        .querySelector('meta[name="csrf-token"]')
        ?.getAttribute("content");

      try {
        const response = await fetch("/api/v1/llm/chat", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
            ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {})
          },
          body: JSON.stringify({
            messages: conversationHistory
          })
        });

        if (!response.ok) {
          const errorText = await response.text();

          throw new Error(
            `Request failed with status ${response.status}` +
            (errorText ? `: ${errorText}` : "")
          );
        }

        const data = await response.json();

        // Extract TeSS data.
        const tess = data?.tess || {};

        // Extract the LLM response.
        const rawAnswer =
          typeof data?.llm?.answer === "string"
          ? data.llm.answer
          : data?.llm?.answer?.choice?.[0]?.message?.content ||
            data?.llm?.answer?.choice?.[0]?.text ||
            data?.llm?.choice?.[0]?.message?.content ||
            "No EGI LLM response available!";

        // Remove the loading indicator.
        loadingMessage.remove();

        // Separate the LLM answer from the embedded TeSS headings
        let llm = String(rawAnswer);
        const llmMarker = "[LLM]";
        const llmIndex = llm.lastIndexOf(llmMarker);

        if (llmIndex !== -1) {
          llm = llm.slice(llmIndex + llmMarker.length).trim();
        }

        // Format and display structured TeSS results
        const tessText = formatTess(tess);
        appendSection("tess", "[TeSS]", tessText);

        // Display the LLM response separately
        appendSection("llm", "[LLM]", String(llm));

        // Save the combined assistant response for future conversation turns
        conversationHistory.push({
          role: "assistant",
          content: llm
          //content: `[TeSS]\n${tessText}\n\n[LLM]\n${String(llm)}`
        });

        // Keep the most recent 20 messages.
        if (conversationHistory.length > 20) {
          conversationHistory = conversationHistory.slice(-20);
        }
      } catch (error) {
        console.error("EGI Chat Error:", error);

        loadingMessage.remove();

        appendMessage(
          "assistant",
          `Response failed: ${error.message}`
        );

        // Remove the failed user message from history so it can
        // be retried without retaining an unanswered request.
        const lastMessage =
          conversationHistory[conversationHistory.length - 1];

        if (lastMessage && lastMessage.role === "user") {
          conversationHistory.pop();
        }
      } finally {
        isSending = false;
        sendBtn.disabled = false;
        inputField.disabled = false;
        inputField.focus();
      }
    }

    // Add a plain-text message to the transcript.
    function appendMessage(role, text) {
      const msgDiv = document.createElement("div");

      msgDiv.classList.add("chat-msg", role);
      msgDiv.textContent = text;

      messagesContainer.appendChild(msgDiv);
      messagesContainer.scrollTop = messagesContainer.scrollHeight;

      return msgDiv;
    }

    // FIXME: not used - maybe it is missing or should be deleted
    // Escape HTML to prevent resource data from injecting markup.
    function escapeHtml(value) {
      return String(value).replace(/[&<>"']/g, function (char) {
        return {
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;"
        }[char];
      });
    }
    
    // Format TeSS API results.
    function formatTess(tess = {}) {
      tess = tess || {};

      const sections = [
        ["Events", tess.events],
        ["Materials", tess.materials],
        ["Trainers", tess.trainers],
        ["Content providers", tess.content_providers]
      ];

      return sections
        .map(([label, items]) => {
          if (!Array.isArray(items) || items.length === 0) {
            return `- ${label}: None found`;
          }

          const formattedItems = items
            .map((item) => {
              const title = item?.title || item?.name || "Untitled";
              const description = item?.description || "";
              const url = item?.url || "";

              return (` - <strong>${title}:</strong>` +
                (description ? ` ${description}` : "") +
                (url ? `\n    URL: <a href="${url}" target="_blank" rel="noopener noreferres">${url}</a>` : "")
              );
            })
            .join("\n");

          return `- ${label}:\n${formattedItems}`;
        })
        .join("\n\n");
    }
    
    // Add a formatted response section to the transcript.
    function appendSection(role, heading, text) {
      const section = document.createElement("div");
      section.classList.add("chat-section", `chat-section-${role}`);

      const title = document.createElement("div");
      title.classList.add("chat-section-title");
      title.textContent = heading;

      const content = document.createElement("div");
      content.classList.add("chat-section-content");

      if (
        role === "llm" &&
        typeof text === "string" &&
        window.marked &&
        window.DOMPurify
      ) {
        // Parse Markdown and sanitize generated HTML.
        const html = window.marked.parse(text);
        content.innerHTML = window.DOMPurify.sanitize(html);
        content.classList.add("markdown-body");
      } else if (role === "tess") {
        // TeSS results remain plain text.
        content.innerHTML = DOMPurify.sanitize(text, {
          ALLOWED_TAGS: ["a", "strong"],
          ALLOWED_ATTR: ["href", "target", "rel"],
        });
      } else {
        content.textContent = text;
      }

      section.appendChild(title);
      section.appendChild(content);
      messagesContainer.appendChild(section);

      messagesContainer.scrollTop = messagesContainer.scrollHeight;

      return section;
    }

    // Send button.
    sendBtn.addEventListener("click", function (event) {
      event.preventDefault();
      sendMessage();
    });

    // Enter key.
    inputField.addEventListener("keydown", function (event) {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        sendMessage();
      }
    });
  }

  // Normal page load.
  document.addEventListener("DOMContentLoaded", initializeEgiChat);

  // Turbolinks page navigation.
  document.addEventListener("turbolinks:load", initializeEgiChat);
})();