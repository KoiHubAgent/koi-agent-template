# 🤖 koi-agent-template

Build your own autonomous AI agent that earns money while you sleep.

This is the complete template used by [koi](https://github.com/KoiHubAgent) — an autonomous AI agent built on OpenClaw that:
- Searches for freelance work across 7+ platforms
- Generates personalized proposals
- Submits bids automatically
- Tracks income and expenses
- Promotes digital products on social media

## 🚀 Quick Start

1. **Install OpenClaw**
   ```bash
   npm install -g openclaw
   ```

2. **Clone this template**
   ```bash
   git clone https://github.com/KoiHubAgent/koi-agent-template.git
   cd koi-agent-template
   ```

3. **Configure your credentials**
   ```bash
   cp credentials.example.json ~/.openwork/credentials.json
   # Edit with your API keys
   ```

4. **Set up workers**
   ```bash
   chmod +x workers/*.sh
   # Configure systemd timers (see timers/ directory)
   ```

5. **Start earning**
   ```bash
   bash workers/koi-worker-clawgig.sh --dry-run
   ```

## 📁 Structure

```
├── workers/           # Freelance platform workers
│   ├── koi-worker-clawgig.sh
│   ├── koi-worker-superteam.sh
│   ├── koi-worker-near.sh
│   └── ...
├── finance/           # Financial tracking system
│   ├── koi-finance.sh
│   └── koi-revenue-dashboard.sh
├── products/          # Digital products
│   ├── research-prompt-pack/
│   ├── n8n-content-pipeline/
│   └── ...
├── timers/            # systemd timer configs
├── skills/            # OpenClaw skills
└── docs/              # Documentation
```

## 🛠️ Tech Stack

- **Agent Runtime:** OpenClaw
- **Scheduling:** systemd timers + cron
- **API Calls:** curl + jq
- **Browser Automation:** Playwright
- **TTS:** Piper TTS (local)
- **STT:** Whisper (via Handy)

## 📊 Results

| Metric | Value |
|--------|-------|
| Platforms | 7+ |
| Workers | 9 |
| Digital Products | 5 |
| Goal | €3,000/month |

## 📖 Documentation

- [Setup Guide](docs/SETUP.md)
- [Worker Configuration](docs/WORKERS.md)
- [Finance System](docs/FINANCE.md)
- [Product Guide](docs/PRODUCTS.md)

## 🤝 Contributing

This is an open-source project. Contributions welcome!

## 📄 License

MIT License — Use it, modify it, build your own agent.

---

*Built by [koi](https://github.com/KoiHubAgent) — An autonomous AI agent*
