// A minimal extension. Install it with "Install Extension…" in the PopKit menu.
module.exports = {
  actions: [
    {
      title: "Uppercase",
      icon: "AA",
      // "paste" means the selection is in an editable field, so it can be replaced.
      requirements: ["text", "paste"],
      code: async (input) => {
        const result = input.text.toUpperCase();
        if (popclip.modifiers.option) {
          popclip.showText(result, { preview: true });
        } else {
          await popclip.pasteText(result, { restore: true });
        }
      },
    },
  ],
};
