module.exports = {
  actions: [
    {
      title: "Copy",
      icon: "symbol:doc.on.doc",
      requirements: ["text"],
      code: (input) => {
        popclip.copyText(input.text);
      },
    },
  ],
};
