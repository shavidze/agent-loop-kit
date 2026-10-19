# Agent Loop Kit

> **English:** a portable B (planner) → A (implementer) → C (independent verifier) → root gate (verify + review + commit/push) loop for Claude Code on any git repository. Retries usage limits and network errors, restarts test servers, keeps agent context small, measures cost and quality per round. Windows PowerShell 5.1+ or PowerShell 7. Guide (Georgian): `docs/GUIDE.md`.

AI-აგენტების გუნდი ნებისმიერი git პროექტისთვის: **B** გეგმავს, **A** კოდს წერს, **C** დამოუკიდებლად ამოწმებს, **root gate** კი მხოლოდ შემოწმებულ კოდს აკომიტებს და ფუშავს. რეალურ პროექტზე 60+ რაუნდის გამოცდილებიდან გამოვიდა. სრული გზამკვლევი: [`docs/GUIDE.md`](docs/GUIDE.md).

## დაწყება 4 ნაბიჯად

1. **დააკოპირე** ეს საქაღალდე სადმე, მაგალითად `C:\Tools\agent-loop-kit` (ერთი ასლი ყველა პროექტისთვის საკმარისია).
2. **შექმენი კონფიგურაცია:** `loop.config.example.json` → `loop.config.json` (ან `my-app.config.json`) და შეავსე:
   - `repoDir` — პროექტის git საქაღალდე;
   - `loopDir` — ლუპის მეხსიერების საქაღალდე. სასურველია **რეპოს გარეთ** იყოს (მაგ. `C:\Apps\my-app-loop`), რომ ანგარიშები git-ში არ მოხვდეს;
   - `branch`, `pushRemotes` — სად წავიდეს შემოწმებული კოდი;
   - `verifyCommand` — ერთი ბრძანება, რომელიც ყველაფერს ამოწმებს (`npm run verify`, `dotnet build && dotnet test` ...);
   - `servers` — რა უნდა მუშაობდეს C-ის შემოწმებისას: `healthUrl` და გაშვების ბრძანება. თუ შენ პროექტს სერვერი არ აქვს, დატოვე `[]`;
   - `protectedPaths` — ფაილები, რომლებსაც ლუპი ვერასდროს გამოაქვეყნებს (auth, გადახდა, საიდუმლოები).
3. **დაწერე `requirements.md`** `loopDir`-ში: სრული სია, რა გინდა. ქართულად ან ინგლისურად, როგორც გინდა. B მისგან თავად ააწყობს backlog-ს და პირველ დავალებას.
4. **გაუშვი** `start-loop.cmd` (ან `start-loop.ps1 -Config C:\...\my-app.config.json`). გაჩერება: `stop-loop.cmd`.

რა ხდება, ჩანს `loopDir`-ში:
- `status.json` — ახლა რომელი რაუნდი და ფაზაა;
- `loop.log` — ყველა მოქმედება;
- `metrics/summary.md` — ხარჯი, ბაგები, PASS/FAIL;
- `gates/gate-round-N.json` — დაიფუშა თუ არა და რატომ.

საჭიროა: Claude Code CLI (`claude`), git, Node.js. PowerShell 5.1 (Windows-ში ჩაშენებული) ან 7. Python მხოლოდ კონტექსტის watchdog-ისთვის, სურვილისამებრ.

## როგორ მუშაობს ერთი რაუნდი

```
სერვერები (თუ საჭიროა) → კონტექსტი → A კოდს წერს → სერვერები (აუცილებლად) → C ამოწმებს
   → ROOT GATE: C PASS? → verify → დამოუკიდებელი reviewer "COMMIT: OK"? → commit + push
   → B ხურავს რაუნდს და წერს შემდეგ დავალებას → მეტრიკა → შემდეგი რაუნდი
```

- **ლიმიტი ან ქსელის შეცდომა:** ლუპი ელოდება, შემდეგ იმავე ფაზას აგრძელებს და ნამუშევარს არ კარგავს.
- **სერვერი ვერ ჩაირთო:** ლუპი ჩერდება `NEEDS_ATTENTION` სტატუსით. C სერვერის გარეშე არაფერს „ამოწმებს“.
- **Gate:** commit-ს მხოლოდ მაშინ აკეთებს, როცა C = PASS, critical/high ბაგი არ არის, protected ფაილი არ შეცვლილა, verify გადის და reviewer თანახმაა. თითოეული უარის მიზეზი იწერება.
- **აგენტებს `git commit`/`push` ტექნიკურად აკრძალული აქვთ.**

## სად რა არის

| ფაილი | რას აკეთებს |
|---|---|
| `run-loop.ps1` | თავად ლუპი (graph) |
| `agents.json` | 4 როლი: planner (B), implementer (A), verifier (C), reviewer |
| `prompts/*.md` | თითოეული როლის დავალება; `{{ROUND}}`, `{{LOOP}}`, `{{REPO}}` ავტომატურად ივსება |
| `policy.md` | საერთო წესები, ყველა აგენტს ეგზავნება. პროექტის საკუთარი წესები → `loopDir/policy.local.md` |
| `templates/` | backlog-ისა და დავალების ფორმატი, რომელსაც B იყენებს |
| `tools/build-context.mjs` | backlog-ის „აქტიური ხედი“, რომ აგენტებმა მთელი ისტორია არ წაიკითხონ |
| `tools/loop-metrics.mjs` | ყოველი რაუნდის ხარჯი, დრო, ბაგები, gate |
| `tools/watch-context.py` | თუ აგენტის კონტექსტი ევსება, იმავე ფაზას ახალ სესიაში რესტარტავს |

**შენი პროექტის `.claude`** (rules, skills, agents, primitives) **ავტომატურად მოქმედებს**: აგენტები `repoDir`-ში ეშვებიან და Claude Code მის `CLAUDE.md`-სა და `.claude`-ს თავად კითხულობს. კარგი `CLAUDE.md` და პროექტის `code-reviewer` აგენტი ლუპს საგრძნობლად აძლიერებს.

## კარპათის იდეები: სად არის კიტში

| იდეა („Software 1.0/2.0/3.0“ ლექციიდან) | კიტში |
|---|---|
| **Software 3.0:** prompt პროგრამაა, ქცევას ინსტრუქციები და კონტექსტი ცვლის | `prompts/`, `policy.md`, B-ს დავალებები |
| **1.0 და 3.0 ფენებად:** LLM სისტემის შიგნითაა, მაგრამ ზუსტ საქმეს ჩვეულებრივი კოდი აკეთებს | `run-loop.ps1`: სერვერები, retry, gate, commit/push დეტერმინისტულია |
| **სიმულაცია ≠ რეალური მოქმედება** (GPT, რომელიც „Linux terminal“-ს თამაშობს) | C რეალურ პროდუქტს ამოწმებს; `realVerified=false` ნიშნავს, რომ „მზად არ არის“ |
| **Context window შეზღუდულია, მეხსიერება გარეთაა** | ფაილებზე დაფუძნებული მეხსიერება + `build-context.mjs` + checkpoint-ები + watchdog |
| **In-context learning:** მაგალითები კონტექსტში ცვლის ქცევას | `templates/` (ზუსტი ფორმატი), `rules` backlog-ში (წარსული შეცდომებიდან ნასწავლი) |
| **Data Engine** (შეცდომები → მონაცემი → გაუმჯობესება) | `metrics/` + B-ს `rules`: ყოველი ჩავარდნა ახალ წესად იწერება |
| **LLM ფულს და წვდომას არ წყვეტს** (ბანკის მაგალითი) | `protectedPaths`, gate, აგენტებს push-ის აკრძალვა |
| **Agent / Loop / Graph** (ვიდეოს აღწერიდან, თანამედროვე პრაქტიკა) | თავად `run-loop.ps1`-ის სტრუქტურა |

რაც კიტში **არ არის**, რადგან აგენტების ლუპს არ ეხება: მოდელის გაწვრთნა (Software 2.0), Transformer-ის შიგნეულობა, fine-tuning. ეს მაშინ დაგჭირდება, თუ პროდუქტში AI ფუნქციას აკეთებ (მაგ. ძიება embeddings-ით).

## რჩევები

- პირველი რაუნდები უყურე: `loop.log` და `gates/`. როცა ნდობა გაჩნდება, მარტო დატოვე.
- თუ B-ს `b-next.json` = `BLOCKED`, მან შენგან რაღაც იკითხა: იხილე `b-round-N.md`.
- ხარჯს მეტრიკა აჩვენებს. ძვირი რაუნდი ხშირად ძალიან დიდ დავალებას ნიშნავს: სთხოვე B-ს, უფრო პატარად დაყოს.
- Windows-ის ხაფანგები უკვე გათვალისწინებულია: UTF-8 stdin, 5.1-ის stderr, `pwsh`/`powershell`, CRLF-ის მხოლოდ ცვლილებები.
