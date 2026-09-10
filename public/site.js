(() => {
    async function copyText(button) {
        const value = button.dataset.copy || "";
        if (!value) return;

        try {
            await navigator.clipboard.writeText(value);
        } catch {
            const area = document.createElement("textarea");
            area.value = value;
            area.setAttribute("readonly", "");
            area.style.position = "fixed";
            area.style.opacity = "0";
            document.body.appendChild(area);
            area.select();
            document.execCommand("copy");
            area.remove();
        }

        const original = button.textContent;
        button.textContent = "Copied";
        window.setTimeout(() => { button.textContent = original; }, 1500);
    }

    document.addEventListener("click", (event) => {
        const button = event.target.closest(".copy-button");
        if (button) copyText(button);
    });
})();
