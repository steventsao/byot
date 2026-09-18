// Disposable OpenCode v1 auth plugin. Never accesses a real provider account.
export const BYOTAuthFixture = async () => ({
  auth: {
    provider: "byot-auth-fixture",
    methods: [{
      type: "oauth", label: "BYOT code fixture",
      prompts: [{type: "select", key: "account", message: "Account",
        options: [{label: "Personal", value: "personal"}]}],
      authorize: async (inputs) => ({
        url: "https://auth.example.test/fixture", method: "code",
        instructions: "Use the synthetic fixture code",
        callback: async (code) => code === "fixture-code" && inputs.account === "personal"
          ? {type: "success", key: "synthetic-fixture-only"} : {type: "failed"}
      })
    }]
  }
});
