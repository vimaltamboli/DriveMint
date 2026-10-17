module.exports = {
  env: {
    es6: true,
    node: true,
  },

  parserOptions: {
    ecmaVersion: 2022,
  },

  extends: [
    "eslint:recommended",
  ],

  rules: {
    quotes: [
      "error",
      "double",
      {
        allowTemplateLiterals: true,
      },
    ],
    "no-unused-vars": "warn",
  },
};