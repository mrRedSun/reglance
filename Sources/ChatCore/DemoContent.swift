import Foundation

/// The made-up chats and canned replies demo mode shows. Keep them short, friendly and
/// varied: they are what the README screenshots show off.
public enum DemoContent {
    public struct Reply: Sendable {
        public var keyword: String
        public var question: String
        public var title: String
        public var tools: [ToolStep] = []
        public var text: String
    }

    /// The question the hero scene types into the floating bar.
    public static let heroQuestion = "How much caffeine is in coffee vs. tea?"
    /// The question the attachments scene types next to its floor plan and lease.
    public static let attachmentQuestion = "Does this floor plan match what the lease says?"

    public static let caffeine = Reply(
        keyword: "caffeine", question: heroQuestion, title: "Caffeine in coffee and tea",
        tools: [ToolStep(name: "WebSearch", detail: "caffeine mg per cup coffee espresso tea")],
        text: """
            Coffee has roughly **two to three times** the caffeine of tea, cup for cup. \
            Brewing time and the beans or leaves matter more than the drink's name.

            ```chart
            {"type":"bar","title":"Caffeine per serving (approx.)","y_label":"mg","data":[{"x":"Drip coffee","y":95,"highlight":true},{"x":"Espresso","y":63},{"x":"Black tea","y":47},{"x":"Green tea","y":28},{"x":"Decaf","y":3}]}
            ```

            - A double espresso (about 126 mg) beats a mug of black tea by a wide margin.
            - Matcha is the exception among teas: you drink the whole leaf, so it can reach 70 mg.
            """
    )

    public static let lisbon = Reply(
        keyword: "lisbon", question: "Plan a 3-day Lisbon trip for two, mostly food and walking.",
        title: "Lisbon long weekend",
        text: """
            Here's a relaxed plan that keeps each day in one part of the city, so you walk more \
            and ride less.

            ```document
            title: Lisbon long weekend
            ## Day 1 · Alfama and Baixa
            - Morning: tram 28 up to Miradouro de Santa Luzia
            - Lunch: grilled sardines in Alfama
            - Evening: fado in a small tasca, book ahead

            ## Day 2 · Belém
            - Pastéis de Belém before the line builds (aim for 9:00)
            - Jerónimos Monastery, then the riverside walk to LX Factory

            ## Day 3 · Príncipe Real and Bairro Alto
            - Saturday market in Príncipe Real
            - Sunset at Miradouro de São Pedro de Alcântara
            ```

            Comfortable shoes matter more than anything else on this list. The hills are steep \
            and the cobbles are slippery.
            """
    )

    public static let compound = Reply(
        keyword: "compound", question: "Explain compound interest with something I can play with.",
        title: "Compound interest explained",
        text: """
            Compound interest means you earn interest on your interest too, so growth speeds up \
            the longer you wait. Drag the sliders to see it:

            ```html
            <!doctype html>
            <meta name="color-scheme" content="light dark">
            <style>
              body { font: 14px -apple-system, sans-serif; margin: 0; padding: 8px 4px; background: transparent; }
              label { display: grid; grid-template-columns: 120px 1fr 64px; align-items: center; gap: 10px; margin: 8px 0; }
              input { accent-color: #0a84ff; }
              .total { font-size: 30px; font-weight: 600; margin-top: 14px; }
              .note { opacity: .6; }
            </style>
            <label>Monthly saving <input id="m" type="range" min="50" max="1000" step="50" value="300"><span id="mv"></span></label>
            <label>Yearly return <input id="r" type="range" min="1" max="10" value="6"><span id="rv"></span></label>
            <label>Years <input id="y" type="range" min="1" max="40" value="20"><span id="yv"></span></label>
            <div class="total" id="t"></div>
            <div class="note" id="n"></div>
            <script>
              const $ = id => document.getElementById(id);
              const fmt = n => n.toLocaleString(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 0 });
              function update() {
                const m = +$("m").value, r = +$("r").value / 100 / 12, n = +$("y").value * 12;
                const total = m * ((Math.pow(1 + r, n) - 1) / r);
                $("mv").textContent = fmt(m); $("rv").textContent = $("r").value + "%"; $("yv").textContent = $("y").value;
                $("t").textContent = fmt(total);
                $("n").textContent = fmt(m * n) + " saved, " + fmt(total - m * n) + " earned in interest";
              }
              document.querySelectorAll("input").forEach(i => i.oninput = update);
              update();
            </script>
            ```

            After 20 years at 6%, a bit over a third of the total is interest you never paid in.
            """
    )

    public static let dogs = Reply(
        keyword: "bark", question: "Which dogs can't bark?", title: "Dogs that can't bark",
        text: """
            The **Basenji** is the famous one. Its larynx is shaped differently, so instead of \
            barking it makes a yodel-like sound called a *barroo*.

            A few others are quiet rather than barkless:
            - **New Guinea singing dog**: howls in a rising, almost musical tone
            - **Shiba Inu**: rarely barks, but has a piercing "Shiba scream"
            - **Greyhound**: can bark, usually doesn't bother
            """
    )

    public static let sourdough = Reply(
        keyword: "sourdough", question: "What's a simple feeding schedule for a sourdough starter?",
        title: "Sourdough starter schedule",
        text: """
            For a starter kept on the counter, feed it once a day at the same time:

            1. Discard all but 50 g of starter
            2. Add 50 g flour and 50 g lukewarm water
            3. Stir, loosely cover, and mark the level with a rubber band

            It's ready to bake with when it doubles within 4 to 6 hours of feeding. In the \
            fridge, once a week is enough.
            """
    )

    public static let blog = Reply(
        keyword: "links", question: "Find and fix the broken links in my blog posts.",
        title: "Fix broken blog links",
        tools: [
            ToolStep(name: "Grep", detail: "https?://", textOffset: 0),
            ToolStep(name: "Bash", detail: "npx linkinator ./public --recurse", textOffset: 0),
            ToolStep(name: "Edit", detail: "content/posts/moving-to-swift.md", textOffset: 0),
        ],
        text: """
            I checked 214 links across 38 posts and fixed the 3 that were broken:

            - `moving-to-swift.md`: Swift Evolution moved to a new URL
            - `home-network.md`: the router manual link now points to the archived copy
            - `about.md`: removed a link to a talk that is no longer online

            The rebuilt site passes the link check with no errors.
            """
    )

    public static let fallback = Reply(
        keyword: "", question: "", title: "Demo chat",
        text: """
            This is Reglance's **demo mode**, so replies are canned and no message leaves your \
            Mac. Quit and reopen Reglance without `REGLANCE_DEMO` to ask Claude for real.
            """
    )

    static let replies = [caffeine, lisbon, compound, dogs, sourdough, blog]

    public static func reply(to question: String) -> Reply {
        let lowered = question.lowercased()
        return replies.first { lowered.contains($0.keyword) } ?? fallback
    }

    /// The library a demo starts with, newest first, with dates relative to `now`.
    static func chats(now: Date) -> [Chat] {
        func chat(_ reply: Reply, hoursAgo: Double, pinned: Bool = false, archived: Bool = false,
                  model: ClaudeModel = .sonnet, agentDirectory: URL? = nil) -> Chat {
            let asked = now.addingTimeInterval(-hoursAgo * 3600)
            var chat = Chat(firstMessage: reply.question, model: model, agentDirectory: agentDirectory)
            chat.title = reply.title
            chat.titleIsAutomatic = false
            chat.createdAt = asked
            chat.updatedAt = asked.addingTimeInterval(20)
            chat.isPinned = pinned
            chat.isArchived = archived
            chat.sessionID = UUID().uuidString
            var question = Message(role: .user, text: reply.question)
            question.createdAt = asked
            var answer = Message(role: .assistant, text: reply.text)
            answer.createdAt = asked.addingTimeInterval(20)
            answer.sessionID = chat.sessionID
            if !reply.tools.isEmpty { answer.toolSteps = reply.tools }
            chat.messages = [question, answer]
            return chat
        }
        let gifts = Reply(keyword: "", question: "Gift ideas for someone who loves hiking, under $50",
                          title: "Hiking gift ideas",
                          text: "A good headlamp, merino socks, or a trail guide for their local area all land well.")
        return [
            chat(lisbon, hoursAgo: 30, pinned: true, model: .opus),
            chat(compound, hoursAgo: 0.5),
            chat(blog, hoursAgo: 3, agentDirectory: URL(filePath: "/Users/demo/Sites/blog", directoryHint: .isDirectory)),
            chat(dogs, hoursAgo: 5, model: .haiku),
            chat(sourdough, hoursAgo: 52),
            chat(gifts, hoursAgo: 24 * 9, archived: true),
        ]
    }
}
