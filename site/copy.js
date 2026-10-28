// The website's own wording: only what the owner signed off (the "Copy" section and the captions,
// labels and page titles in "Design"). Everything else on the site is read from the repo at build time.
// Text in `backticks` is shown as code; X.Y.Z and N are filled in by site/build.js.
"use strict";

module.exports = {
  tagline: "One person, a whole team. Build anything with AI agents, and stay in charge.",

  titles: {
    home: "Cabinet: one person, a whole team",
    docsOverview: "Overview | Cabinet docs",
    doc: "%s | Cabinet docs",
    changelog: "Changelog | Cabinet",
    kind: "Cabinet for %s",
    faq: "Questions | Cabinet",
    notFound: "Page not found | Cabinet",
  },

  nav: {
    tour: "Tour", docs: "Docs", useCases: "Use cases", faq: "FAQ", changelog: "Changelog",
    search: "Search", github: "GitHub", menu: "Menu", close: "Close", skip: "Skip to content",
  },

  footer: {
    forAgents: "For agents: llms.txt",
    license: "Open source under the Apache 2.0 license.",
    built: "Built from version X.Y.Z",
    npm: "npm",
  },

  copyButton: { copy: "Copy", copied: "Copied", failed: "Could not copy. Select the text and copy it." },

  hero: {
    headline: "One person, a whole team.",
    subline: "Build anything with AI agents, and stay in charge.",
    lead: "Cabinet is an open source kit that gives your project a small company of AI agent roles. They bring the skills and the hours. You bring the vision, the judgment and the final say.",
    install: "npm i -g @tarekraafat/cabinet",
    tour: "Take the tour",
    docs: "Read the docs",
  },

  terminal: {
    chip: "Real output",
    pause: "Pause", play: "Play", replay: "Replay",
    caption: "The real output of `cabinet init` X.Y.Z, captured in a sandbox. The home folder shows as /Users/maya.",
    noJs: "Turn on JavaScript to watch it type. The whole output is here either way.",
  },

  whatItIs: {
    h2: "What is Cabinet?",
    answer: "A kit you install with npm. It creates a workspace of plain Markdown files and shell scripts, kept in git on your own machine, that the agent tool you already use can run.",
    doesH3: "What does it do, exactly?",
    does: [
      ["Roles with clear authority.", "A chief of staff, a product manager, an architect, qa, security, a design lead, builders that work in each repo the way it is already built, and any role your project needs, drafted for it from a one-line brief. Every piece of work has exactly one owner."],
      ["Handoffs.", "One log where roles pass work to each other, so nothing is lost when a session ends and you can see everything in flight."],
      ["A daily brief.", "Every morning, every decision only you can make, in one sign-off queue: a plain question, lettered options, the experts' recommendations, and whether it can be undone. You answer in one message."],
      ["Independent review.", "The role that built something never verifies it. qa and security do, and either can hold it back until it is fixed."],
      ["Guardrails.", "In each supported agent tool, push, merge, release and publish stay with you, and a push gate asks you at your own terminal. The guardrails page says what each tool's rules can and cannot block."],
      ["Schedules and encrypted backups,", "on macOS and Linux."],
    ],
  },

  tour: {
    h2: "See how it works",
    intro: "The team a workspace gives you, and one piece of work from handoff to push. Everything marked Example is made up for this tour; the rest is the kit's real output.",
    real: "Real output",
    example: "Example",
    exampleCaption: "Example: made up for this tour, in the kit's real formats.",
    team: {
      h3: "Meet the team",
      caption: "The roles a new workspace turns on, around one table. Choose one to see what it does. The open place is yours.",
      you: "You",
      ownerTitle: "You, the owner",
      ownerText: "You bring the vision, the judgment and the final say. Every decision that is irreversible, public or costs money waits for you in the sign-off queue.",
      more: "More roles: builders for each kind of repo, optional specialists, and any role your project needs, drafted for it.",
      call: "Call a role from a session with `@agent-product-manager` in Claude Code, or in any other tool in plain words: \"As product-manager, read agents/product-manager.md and ...\"",
      noJs: "Turn on JavaScript to choose a role. Every role is listed below.",
    },
    work: {
      h3: "One piece of work, start to finish",
      back: "Back", next: "Next", again: "Start again", stepOf: "Step N of 5",
      steps: [
        ["Hand it on", "The design lead finishes the checkout screens and files a handoff for qa. Every handoff is one entry in one log, so nothing is lost when a session ends."],
        ["Independent review", "qa and security check the work. The role that built it never verifies it, and either one can hold it back."],
        ["Your morning brief", "Every decision only you can make waits in one sign-off queue: a plain question, the options, the experts' recommendations, and whether it can be undone."],
        ["One line from you", "You answer in one message. The team puts each answer where it belongs and carries on."],
        ["Only you push", "No agent can push, merge, release or publish. The push gate asks you, at your own terminal."],
      ],
      verdicts: [
        "- Verdict: qa PASS 2026-10-22 8a71d04 specs/qa/2026-10-22-checkout.md",
        "- Verdict: security PASS 2026-10-22 8a71d04 specs/security/2026-10-22-checkout.md",
      ],
      brief: [
        "Today: 1 decision, 1 action, about 2 min.",
        "## Sign-off queue",
        "1. Merge the checkout redesign? qa and security passed. Evidence: the checkout page.",
        "A: merge.   B: hold.   Design lead: A.",
        "Recommended: A. Undo: yes.",
        "## Actions for the owner",
        "Push web, main at 8a71d04: the checkout redesign, ready to push.",
      ],
      reply: ["you  approve 1", "chief-of-staff", "Applied. 1: approved. Ready for you: push web, main at 8a71d04."],
      // The push gate's prompt is read from guardrails/pre-push; these fill its two blanks and follow "yes", as in the film.
      pushRemote: "git@github.com:acme/web.git",
      pushRefs: "refs/heads/main 8a71d04e2c9b6f3d1a5e7c0b4f8d2a6e9c3b1f57 refs/heads/main 3f2c9e1b7a4d8c6e0f2b5a9d3c7e1f4b8a6d2c09",
      pushed: ["To github.com:acme/web.git", "   3f2c9e1..8a71d04  main -> main"],
    },
    demo: {
      h3: "Watch the demo",
      button: "Play the demo",
      caption: "From an empty folder to a working team and the owner's first morning. The commands and their output are real; the brief and the replies are examples.",
      chapters: "In the film: create the team, set up the machine, check everything, the morning brief, answering in one line, the team at work, only you push.",
      error: "The demo could not load.",
      github: "Watch it on GitHub",
    },
  },

  use: {
    h2: "What would I use it for?",
    answer: "To build more than you could alone: a product, an app or a website, a design system, a book or a newsletter, a launch, an album, a business plan. You set the direction and answer the decisions; the roles plan, build, review and report back.",
    helpH3: "How does it help me?",
    help: "You spend your time on decisions, not on chasing work. The brief is one read in the morning, your answers go where they belong, and nothing irreversible, public or costly happens without you.",
    storyLabel: "From the author",
    storyH3: "Built the way it was used.",
    story: "Cabinet started as its author's own setup. Working alone, he has the agents do most of the work across product, design, development and writing while he brings the vision and signs off, and his output grew about tenfold. With a team of five on a project that needed three times as many people, it gave each person two more teammates. Cabinet is built and maintained with Cabinet.",
  },

  kinds: [
    ["code", "Code", "Builders work in each repo the way it is already built, with tests. qa and security review every change, and a code reviewer can too, before you push."],
    ["design", "Design", "A design lead designs each screen and its states before anything is built, and keeps every surface inside your brand guide."],
    ["writing", "Writing", "Specs, docs, articles or a book, drafted by roles made for the work, reviewed before you publish them."],
    ["marketing", "Marketing", "Campaigns and copy planned and drafted by the team. Public copy and any spend wait for your sign-off."],
    ["music", "Music", "Plans, briefs, release schedules and notes handled by roles drafted for your project. The music and the release stay yours."],
    ["finance", "Finance", "A finance role models pricing, costs and margins from your real numbers, and brings you priced options with a recommendation. You set the prices."],
  ],
  kindPage: {
    label: "Use cases",
    link: "Cabinet for %s",
    todayLabel: "Today",
    today: "Today Cabinet's defaults are made for code. Other work runs through roles drafted for it and specs in the workspace, and making that path as complete is planned.",
    dayH2: "A day with Cabinet",
    installH2: "Install",
    otherH2: "Other kinds of work",
  },

  install: {
    h2: "Install",
    tabs: ["macOS", "Linux"],
    agentH3: "Set up with your agent",
    agentCaption: "Paste this into your agent tool. It reads the setup guide, asks you what it needs, and shows you every change before it makes it.",
    agentText: "Set up Cabinet for me, following https://tarekraafat.github.io/cabinet/docs/agent-setup.md (the docs for agents: https://tarekraafat.github.io/cabinet/llms.txt)",
    changes: "What changes",
    undo: "How to undo it",
  },

  closing: { h2: "Questions?", faq: "Read the FAQ", docs: "Read the docs" },

  docs: {
    docs: "Docs", onThisPage: "On this page", anchor: "Link to this section", previous: "Previous", next: "Next", forAgents: "For agents",
    overview: "Overview",
    order: ["README.md", "docs/tutorial.md", "docs/recipes.md", "docs/commands.md", "docs/concepts.md", "docs/layouts.md", "docs/guardrails.md", "docs/backups.md", "docs/troubleshooting.md"],
    agents: ["docs/agent-setup.md"],
    lookup: {
      h2: "Find a fix",
      placeholder: "Paste a line from cabinet doctor, or a check ID such as deps.node",
      check: "Check", cause: "Cause", fix: "Fix",
      none: "No check matches that. Every message is listed below, by topic.",
    },
  },

  search: {
    label: "Search the docs",
    empty: "Type a command, an option or a topic, or paste a line from cabinet doctor.",
    loading: "Loading the search index...",
    failed: "Search could not load.",
    none: "Nothing matches \"<query>\".",
    browse: "Browse all docs",
    hint: "Enter to open. Up and Down to move. Esc to close.",
    close: "Close",
    // The empty state's four quick links: [label, docs page, heading anchor].
    quick: [["Quick start", "README.md", "quick-start"], ["Commands", "docs/commands.md", ""], ["Troubleshooting", "docs/troubleshooting.md", ""], ["Guardrails", "docs/guardrails.md", ""]],
  },

  changelog: {
    h2: "Upgrade notes",
    from: "From the version you have",
    to: "To",
    range: "Changes from X.Y.Z to X.Y.Z, newest first",
    byHand: "To do by hand after `npx cabinet update`",
    same: "Both are X.Y.Z, so nothing changed between them.",
    reset: "Show every version",
  },

  faq: {
    h1: "Questions",
    picker: "Choose your agent tool",
    blocks: "What its rules block",
    notCaught: "Not caught by any tool's rules",
    limits: "Known limits",
    items: [
      { q: "Is Cabinet another AI assistant?", a: ["No. An assistant is one helper you talk to. Cabinet is how a team of agents works for you: separate roles, each owning its part with clear authority, passing work through handoffs, reviewing each other's work, and bringing you only the decisions that are yours. It runs on the agent tool you already use."] },
      { q: "How is Cabinet different?", list: [
        "A team, not one helper: roles with clear authority, one owner for every piece of work.",
        "You keep the final say: push, merge, release and publish stay with you, held by guardrails.",
        "Independent review: the role that built something never verifies it.",
        "Plain files in git on your machine: readable, versioned and yours. Cabinet itself runs no server.",
        "Any supported agent tool, and you can change tools later.",
        "For work that is not code too: design, writing, marketing, music, finance.",
      ] },
      { q: "Can an agent push, merge, release or publish?", a: ["No supported agent tool's rules allow it, and a push gate asks you at your own terminal before any push. Each tool's rule format differs; the guardrails page lists what each one blocks and its known limits."] },
      { q: "Which agent tools does Cabinet support?", tools: true, other: "any other tool that reads `AGENTS.md`" },
      { q: "Does Cabinet change my machine?", a: ["Only when you run `cabinet bootstrap`, which shows a dry run first."], setup: true },
      { q: "Where does my work live?", a: ["In a workspace folder on your machine, its own git repo. Cabinet runs no server and has no account to sign up for."] },
      { q: "What does it cost?", a: ["Cabinet is open source under the Apache 2.0 license. The agent tool you run it with has its own terms."] },
    ],
  },

  notFound: {
    h1: "This page is not here",
    line: "It may have moved when the docs changed. Search, or start from the docs.",
    docs: "Docs", home: "Home",
  },
};
