// Works on any selection, editable or not, and never touches the selection itself.
module.exports = {
  actions: [
    {
      title: "Count words",
      icon: "symbol:number",
      requirements: ["text"],
      code: (input) => {
        const words = input.text.trim().split(/\s+/).filter(Boolean).length;
        const chars = input.text.length;
        // A plain notice: shown for a moment, then hidden.
        popclip.showText(`${words} word${words === 1 ? "" : "s"}, ${chars} character${chars === 1 ? "" : "s"}`);
      },
    },
  ],
};
