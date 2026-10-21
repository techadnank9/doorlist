import SwiftUI
import WebKit

// MARK: - Page script

/// Reads and fills the event page's own form. Runs in the page and in its
/// same-site frames (where Eventbrite's checkout lives). It never touches
/// password, payment or one-time code fields.
private let pageScript = #"""
(() => {
  if (window.__doorlist) return;
  const D = window.__doorlist = {};
  let next = 1;

  const docs = () => {
    const out = [document];
    for (const f of document.querySelectorAll('iframe')) {
      try { if (f.contentDocument && f.contentDocument.body) out.push(f.contentDocument); } catch (e) {}
    }
    return out;
  };
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const text = el => el ? clean(el.innerText || el.textContent) : '';
  const visible = el => {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const s = el.ownerDocument.defaultView.getComputedStyle(el);
    return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
  };
  const tag = el => {
    if (!el.dataset.doorlistId) el.dataset.doorlistId = 'f' + (next++);
    return el.dataset.doorlistId;
  };
  const labelFor = el => {
    const d = el.ownerDocument;
    if (el.id) {
      const l = d.querySelector('label[for="' + CSS.escape(el.id) + '"]');
      if (l && text(l)) return text(l);
    }
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const t = clean(by.split(/\s+/).map(i => text(d.getElementById(i))).join(' '));
      if (t) return t;
    }
    const aria = el.getAttribute('aria-label');
    if (aria) return clean(aria);
    const wrap = el.closest('label');
    if (wrap && text(wrap)) return text(wrap);
    let node = el;
    for (let i = 0; i < 4 && node; i++) {
      node = node.parentElement;
      if (!node) break;
      const copy = node.cloneNode(true);
      copy.querySelectorAll('input,textarea,select,option,button,svg').forEach(x => x.remove());
      const t = text(copy);
      if (t && t.length < 220) return t;
    }
    return clean(el.placeholder || el.name || '');
  };
  const isSecret = el => {
    const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
    const type = (el.type || '').toLowerCase();
    const hint = (labelFor(el) + ' ' + (el.name || '') + ' ' + (el.id || '')).toLowerCase();
    return type === 'password' || ac.startsWith('cc-') || ac === 'one-time-code' ||
      /\b(card|cvc|cvv|expir|security code|verification code|one.time|otp|passcode|password)\b/.test(hint) ||
      (/\bcode\b/.test(hint) && !/(zip|postal|promo|discount|coupon|country)/.test(hint));
  };

  D.scan = () => {
    const fields = [], buttons = [], groups = {}, passwords = [];
    let secretField = false, paymentFrame = false, captcha = false;
    for (const d of docs()) {
      for (const f of d.querySelectorAll('iframe')) {
        if (/stripe|braintree|adyen|paypal|checkout\.com|recurly/i.test(f.src || '')) paymentFrame = true;
        if (/recaptcha|hcaptcha|challenges\.cloudflare|turnstile|arkoselabs|funcaptcha/i.test(f.src || '') && visible(f)) captcha = true;
      }
      for (const el of d.querySelectorAll('input, textarea, select')) {
        const type = (el.type || el.tagName).toLowerCase();
        if (['hidden', 'submit', 'button', 'image', 'reset', 'file', 'search', 'range', 'color'].includes(type)) continue;
        if (el.disabled || el.readOnly) continue;
        // Styled checkboxes and radios often hide the real input behind their label,
        // so those count as visible when the label (or wrapper) is.
        if (type === 'radio' || type === 'checkbox') {
          const holder = el.closest('label') || (el.id && el.ownerDocument.querySelector('label[for="' + CSS.escape(el.id) + '"]')) || el.parentElement;
          if (!visible(el) && !(holder && visible(holder))) continue;
        } else if (!visible(el)) continue;
        if (type === 'password') {
          // Sign in or a new account: the site's own hints, then the wording around the field.
          const hint = (labelFor(el) + ' ' + (el.name || '') + ' ' + (el.id || '')).toLowerCase();
          const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
          passwords.push({ id: tag(el), filled: !!el.value,
            isNew: ac === 'new-password' || /confirm|create|choose|new|re-?enter|repeat|again|verify/.test(hint) });
          continue;
        }
        if (isSecret(el)) { if (visible(el)) secretField = true; continue; }
        const required = el.required || el.getAttribute('aria-required') === 'true' ||
          /\*\s*$|\(required\)/i.test(labelFor(el));
        if (type === 'radio') {
          const key = el.name || tag(el);
          const g = groups[key] || (groups[key] = { id: 'g:' + key, type: 'radio', options: [], required: false, value: '', label: '' });
          const opt = labelFor(el);
          g.options.push(opt);
          if (el.checked) g.value = opt;
          g.required = g.required || required;
          if (!g.label) {
            const set = el.closest('fieldset');
            const legend = set && set.querySelector('legend');
            const holder = el.closest('[role=radiogroup]');
            g.label = text(legend) || (holder && clean(holder.getAttribute('aria-label'))) || '';
            if (!g.label) {
              let node = el.parentElement;
              for (let i = 0; i < 5 && node; i++, node = node.parentElement) {
                if (node.querySelectorAll('input[type=radio]').length > 1) {
                  const copy = node.cloneNode(true);
                  copy.querySelectorAll('input,label,svg').forEach(x => x.remove());
                  g.label = text(copy).slice(0, 200);
                  if (g.label) break;
                }
              }
            }
          }
          el.dataset.doorlistGroup = key;
          continue;
        }
        fields.push({
          id: tag(el), type, label: labelFor(el).slice(0, 300), required,
          autocomplete: (el.getAttribute('autocomplete') || '').toLowerCase(),
          name: (el.name || '').toLowerCase(),
          value: type === 'checkbox' ? String(el.checked) : (el.value || ''),
          options: el.tagName === 'SELECT' ? [...el.options].map(o => clean(o.text)) : null,
        });
      }
      for (const b of d.querySelectorAll('button, [role=button], input[type=submit], a[href]')) {
        if (!visible(b) || b.disabled || b.getAttribute('aria-disabled') === 'true') continue;
        const t = clean(b.innerText || b.value || b.getAttribute('aria-label'));
        if (!t || t.length > 40) continue;
        buttons.push({ id: tag(b), text: t, isLink: b.tagName === 'A' });
      }
    }
    for (const g of Object.values(groups)) fields.push({ ...g, autocomplete: '', name: '' });

    const meta = n => {
      const m = document.querySelector('meta[property="' + n + '"], meta[name="' + n + '"]');
      return m ? m.content : null;
    };
    let start = null, place = null;
    for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        const items = [].concat(JSON.parse(s.textContent));
        for (const item of items.flatMap(i => i['@graph'] || [i])) {
          if (/Event/.test([].concat(item['@type']).join(' '))) {
            start = start || item.startDate || null;
            const loc = [].concat(item.location || [])[0];
            place = place || (loc && ((loc.address && (loc.address.addressLocality || loc.address.streetAddress)) || loc.name)) || null;
          }
        }
      } catch (e) {}
    }
    const body = docs().map(d => d.body ? d.body.innerText : '').join('\n');
    return JSON.stringify({
      fields, buttons, secretField, paymentFrame, captcha,
      // Two password boxes on one form is a sign up even when neither says so.
      passwords: passwords.length > 1 ? passwords.map(p => ({ ...p, isNew: true })) : passwords,
      text: body.slice(0, 20000),
      title: meta('og:title') || document.title, image: meta('og:image'), start, place,
    });
  };

  const find = id => {
    for (const d of docs()) {
      const el = d.querySelector('[data-doorlist-id="' + id + '"]');
      if (el) return el;
    }
    return null;
  };
  const fire = (el, names) => names.forEach(n => el.dispatchEvent(new Event(n, { bubbles: true })));

  D.fill = (id, value) => {
    if (id.startsWith('g:')) {
      const key = id.slice(2);
      for (const d of docs()) {
        for (const r of d.querySelectorAll('input[type=radio]')) {
          if (r.dataset.doorlistGroup === key && labelFor(r) === value) { r.click(); return true; }
        }
      }
      return false;
    }
    const el = find(id);
    if (!el) return false;
    el.focus();
    if (el.type === 'checkbox') {
      if (String(el.checked) !== value) el.click();
    } else if (el.tagName === 'SELECT') {
      const i = [...el.options].findIndex(o => clean(o.text) === value);
      if (i < 0) return false;
      el.selectedIndex = i;
      fire(el, ['input', 'change']);
    } else {
      const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
      fire(el, ['input', 'change']);
    }
    el.blur();
    return true;
  };

  D.click = id => {
    const el = find(id);
    if (!el) return false;
    el.click();
    return true;
  };
})();
"""#

// MARK: - What the script reports

struct PageScan: Decodable {
    struct Field: Decodable {
        let id: String
        let type: String
        let label: String
        let required: Bool
        let autocomplete: String
        let name: String
        let value: String
        let options: [String]?
    }
    struct Button: Decodable {
        let id: String
        let text: String
        let isLink: Bool?
    }
    struct Password: Decodable {
        let id: String
        let filled: Bool
        /// A new account's password (or its confirmation), not a sign in.
        let isNew: Bool
    }
    let fields: [Field]
    let buttons: [Button]
    let secretField: Bool
    let paymentFrame: Bool
    var captcha: Bool? = nil
    var passwords: [Password]? = nil
    let text: String
    let title: String?
    let image: String?
    let start: String?
    let place: String?
}

/// A required field on the page that nothing remembered could fill.
struct WebAsk: Identifiable, Equatable {
    let id: String
    let label: String
    let options: [String]?
    let multiline: Bool
    let saveKey: String
    let isCheckbox: Bool
}

// MARK: - Model

@MainActor
final class WebBookingModel: ObservableObject {
    enum Phase: Equatable {
        case working(String)
        case needsYou(String)
        case paid
        case done(BookingStatus, alreadyBooked: Bool)
        case paused
    }

    let link: EventLink
    @Published var phase: Phase = .working("Opening the event")
    @Published var asks: [WebAsk] = []
    @Published var progress = 0.0
    @Published private(set) var eventTitle: String?
    @Published private(set) var filledCount = 0
    /// A robot check is on the page, waiting for the person.
    @Published private(set) var needsRobotCheck = false

    weak var webView: WKWebView?
    private var loop: Task<Void, Never>?
    /// A scan is in flight, so the loop and an answer don't run one on top of the other.
    private var ticking = false
    /// Field id -> the value Doorlist put in, so nothing is filled twice.
    private var handled: [String: String] = [:]
    private var clicks: [String: Int] = [:]
    private var lastClick = Date.distantPast
    private var sent: [String: SentAnswer] = [:]
    private var lastScan: PageScan?
    private var finished = false
    private var startedAt = Date()
    /// Confirmation phrases already on the page before Doorlist did anything
    /// (an event blurb saying "see you there"), so they don't count as success.
    private var baseline: Set<String>?

    /// Typed into the site's promo field, then applied, before the price is judged.
    let promoCode: String?
    /// The code is in the field; its Apply button is next.
    private var promoNeedsApply = false
    private var promoApplied = false

    init(link: EventLink, promoCode: String? = nil) {
        self.link = link
        self.promoCode = promoCode
    }

    var platform: EventPlatform { link.platform }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The person takes over: Doorlist stops tapping but keeps watching for success.
    func pause() { phase = .paused }

    func resume() {
        phase = .working("Picking up where you left off")
        clicks = [:]
        startedAt = Date()
    }

    // MARK: Loop

    private func tick() async {
        guard !finished, !ticking, let webView else { return }
        ticking = true
        defer { ticking = false }
        _ = try? await webView.evaluateJavaScript(pageScript)
        guard let raw = try? await webView.evaluateJavaScript("window.__doorlist.scan()") as? String,
              let data = raw.data(using: .utf8),
              let scan = try? JSONDecoder().decode(PageScan.self, from: data) else { return }
        lastScan = scan
        if let title = scan.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            eventTitle = Self.tidyTitle(title)
        }

        let lower = scan.text.lowercased().replacingOccurrences(of: "’", with: "'")
        let found = Self.successPhrases(in: lower)
        if baseline == nil, !scan.text.isEmpty { baseline = Set(found.map(\.phrase)) }
        if let hit = found.first(where: { !(baseline ?? []).contains($0.phrase) }) {
            finish(hit.status, alreadyBooked: false)
            return
        }

        switch phase {
        case .paused, .paid, .done: return
        default: break
        }

        // Doorlist never tries to get past a robot check; it waits, then carries on by itself.
        needsRobotCheck = scan.captcha == true
        if needsRobotCheck {
            phase = .needsYou("Finish the \u{201C}I'm not a robot\u{201D} check")
            return
        }
        if await handleAccount(scan) { return }

        // A code can make a paid ticket free, so it goes in before the price is checked.
        if await applyPromo(scan) { return }

        if Self.looksPaid(lower) || scan.paymentFrame {
            phase = .paid
            return
        }

        await fillKnown(scan)
        if !asks.isEmpty {
            phase = .needsYou(asks.count == 1 ? "One answer needed" : "\(asks.count) answers needed")
            return
        }
        if scan.secretField {
            phase = .needsYou("Type the code \(platform == .web ? "the site" : platform.name) sent you")
            return
        }
        await pressNext(scan)
    }

    // MARK: Fill on request

    /// The person is steering and taps Fill this page: every field Doorlist has an answer for goes in,
    /// and on a sign in form the login Doorlist made for the site. Nothing is tapped or sent.
    func fillNow() async {
        guard !ticking, let webView else { return }
        ticking = true
        defer { ticking = false }
        _ = try? await webView.evaluateJavaScript(pageScript)
        guard let raw = try? await webView.evaluateJavaScript("window.__doorlist.scan()") as? String,
              let data = raw.data(using: .utf8),
              let scan = try? JSONDecoder().decode(PageScan.self, from: data) else { return }
        // Fields the person cleared on purpose get another go.
        handled = [:]
        let before = filledCount
        if let boxes = scan.passwords, let login = SiteLogins.login(for: webView.url?.host) {
            for box in boxes where !box.filled { await fillSecret(box.id, login.password) }
            if let emailField = scan.fields.first(where: { $0.type == "email" || $0.autocomplete.contains("email") || $0.autocomplete == "username" }),
               emailField.value.trimmingCharacters(in: .whitespaces).isEmpty {
                await fill(emailField, login.email, label: emailField.label)
            }
        }
        if let code = promoCode, let promo = scan.fields.first(where: { Self.isPromoField($0.label) }),
           promo.value.trimmingCharacters(in: .whitespaces).isEmpty {
            await fill(promo, code, label: promo.label)
        }
        await fillKnown(scan)
        let count = filledCount - before
        let note = count == 0 ? "Nothing here Doorlist has an answer for yet"
            : "Filled \(count) field\(count == 1 ? "" : "s"). Check them, then tap the page's button."
        if case .paused = phase { pausedNote = note } else { phase = .needsYou(note) }
    }

    /// What Fill this page did, shown while the person is steering.
    @Published private(set) var pausedNote: String?

    /// The page's own words, for Write with AI to read what the event is about.
    var pageText: String? { lastScan?.text }

    // MARK: Accounts

    /// Buttons that send a sign in or sign up form; only tapped while a password box is on the page,
    /// so a "Sign up" link in a site's header is never followed.
    private static let authWords: Set<String> = ["sign in", "log in", "login", "signin", "create account",
                                                  "create an account", "create my account", "sign up", "signup",
                                                  "register", "continue", "next", "submit", "join"]

    /// Signs in with the login Doorlist made for this site, or makes one on a sign up form with the
    /// person's saved name and email and a new random password kept in the Keychain. A sign in form
    /// for a site Doorlist has no login for waits for the person. True while that's happening.
    private func handleAccount(_ scan: PageScan) async -> Bool {
        guard let boxes = scan.passwords, !boxes.isEmpty,
              let site = SiteLogins.site(for: webView?.url?.host) else { return false }
        let empty = boxes.filter { !$0.filled && handled[$0.id] == nil }
        guard !empty.isEmpty else { return await submitAccount(scan) }
        let creating = boxes.contains(where: \.isNew)
        var login = SiteLogins.login(for: site)
        if login == nil {
            guard creating else {
                // A sign in form and no account yet: open the site's own sign up, once.
                let signUpWords: Set<String> = ["sign up", "signup", "create account", "create an account",
                                                "register", "create one", "join now", "get started", "new user? sign up",
                                                "don't have an account? sign up", "no account? create one"]
                if let link = scan.buttons.first(where: { b in
                    let t = Self.norm(b.text)
                    return (signUpWords.contains(t) || t.hasSuffix(" sign up") || t.hasSuffix(" create one")) && (clicks[t] ?? 0) == 0
                }) {
                    clicks[Self.norm(link.text), default: 0] += 1
                    lastClick = Date()
                    phase = .working("Making a \(site) account")
                    _ = try? await webView?.evaluateJavaScript("window.__doorlist.click(\(Self.jsString(link.id)))")
                    return true
                }
                phase = .needsYou("Sign in to \(site) once. Doorlist stays signed in after.")
                return true
            }
            guard let email = AnswerStore.shared.all()["email"]?.value, !email.isEmpty else {
                phase = .needsYou("Add your email in Answers so Doorlist can make your \(site) account")
                return true
            }
            let made = SiteLogin(site: site, email: email, password: SiteLogins.newPassword(), createdAt: Date())
            SiteLogins.save(made)
            sent["account"] = SentAnswer(question: "Account", answer: "Made a \(site) account for \(email). The password is in Other event sites.")
            login = made
        }
        for box in empty { await fillSecret(box.id, login!.password) }
        // The email box: the login's own address, in case it differs from the saved answer.
        if let emailField = scan.fields.first(where: { $0.type == "email" || $0.autocomplete.contains("email") || $0.autocomplete == "username" }),
           emailField.value.trimmingCharacters(in: .whitespaces).isEmpty {
            await fill(emailField, login!.email, label: emailField.label)
        }
        phase = .working(creating ? "Making your \(site) account" : "Signing in to \(site)")
        return true
    }

    /// Everything on the sign in or sign up form is filled: send it.
    private func submitAccount(_ scan: PageScan) async -> Bool {
        await fillKnown(scan)
        guard asks.isEmpty, !scan.secretField, Date().timeIntervalSince(lastClick) > 2.2 else { return !asks.isEmpty }
        guard let button = scan.buttons.first(where: { b in
            b.isLink != true && Self.authWords.contains(Self.norm(b.text)) && (clicks[Self.norm(b.text)] ?? 0) < 2
        }) else { return false }
        clicks[Self.norm(button.text), default: 0] += 1
        lastClick = Date()
        phase = .working("Tapping \(button.text)")
        _ = try? await webView?.evaluateJavaScript("window.__doorlist.click(\(Self.jsString(button.id)))")
        return true
    }

    /// A password goes in without being shown anywhere or added to the answers sent.
    private func fillSecret(_ id: String, _ value: String) async {
        handled[id] = "password"
        _ = try? await webView?.evaluateJavaScript("window.__doorlist.fill(\(Self.jsString(id)), \(Self.jsString(value)))")
    }

    static func isPromoField(_ label: String) -> Bool {
        let l = norm(label)
        return ["promo", "discount", "coupon", "voucher", "access code", "promotional", "redeem", "registration code"]
            .contains { l.contains($0) }
    }

    /// Fills the promo field, then taps its Apply button. True while that's in progress.
    private func applyPromo(_ scan: PageScan) async -> Bool {
        guard let code = promoCode, !promoApplied else { return false }
        if !promoNeedsApply {
            guard let field = scan.fields.first(where: { Self.isPromoField($0.label) && $0.type != "checkbox" }) else {
                // Some checkouts hide the field behind "Have a promo code?"; open it once.
                if let reveal = scan.buttons.first(where: { b in
                    let t = Self.norm(b.text)
                    return Self.isPromoField(t) && (clicks[t] ?? 0) == 0 && !t.hasPrefix("remove")
                }) {
                    clicks[Self.norm(reveal.text), default: 0] += 1
                    phase = .working("Opening the promo code field")
                    _ = try? await webView?.evaluateJavaScript("window.__doorlist.click(\(Self.jsString(reveal.id)))")
                    return true
                }
                return false
            }
            if field.value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(code) != .orderedSame {
                await fill(field, code, label: field.label)
            }
            handled[field.id] = code
            promoNeedsApply = true
            phase = .working("Entered code \(code)")
            return true
        }
        promoNeedsApply = false
        promoApplied = true
        let applyWords: Set<String> = ["apply", "apply code", "apply promo code", "apply coupon", "apply discount",
                                       "redeem", "redeem code", "use code", "submit code", "validate"]
        if let apply = scan.buttons.first(where: { applyWords.contains(Self.norm($0.text)) }) {
            phase = .working("Applying code \(code)")
            _ = try? await webView?.evaluateJavaScript("window.__doorlist.click(\(Self.jsString(apply.id)))")
            lastClick = Date()
            return true
        }
        return false
    }

    private func fillKnown(_ scan: PageScan) async {
        let saved = AnswerStore.shared.all()
        var stillAsk: [WebAsk] = []
        var quantityDone = false

        for field in scan.fields {
            let isCheck = field.type == "checkbox"
            let empty = isCheck ? field.value != "true" : field.value.trimmingCharacters(in: .whitespaces).isEmpty
            guard empty, handled[field.id] == nil else { continue }
            let options = field.options?.filter { !$0.isEmpty && !Self.isPlaceholderOption($0) }

            // Ticket quantity pickers: one ticket, on the first one only.
            if let options, field.type.hasPrefix("select"), options.allSatisfy({ Int($0) != nil }), options.contains("1") {
                if !quantityDone { await fill(field, "1", label: "Tickets") }
                quantityDone = true
                continue
            }

            if isCheck {
                // Required consent boxes follow the Terms setting; optional ones stay off.
                if field.required, Preferences.autoAgree {
                    await fill(field, "true", label: field.label)
                } else if field.required {
                    stillAsk.append(WebAsk(id: field.id, label: Self.cleanLabel(field.label), options: nil,
                                           multiline: false, saveKey: "", isCheckbox: true))
                }
                continue
            }

            if Self.isPromoField(field.label) { continue }

            let key = Self.key(for: field, saved: saved)
            var value = Self.value(for: key, saved: saved)
            if let v = value, let options, !options.isEmpty {
                value = QuestionMatcher.choose(v, from: options)
            }
            if let value {
                await fill(field, value, label: field.label)
            } else if field.required {
                stillAsk.append(WebAsk(id: field.id, label: Self.cleanLabel(field.label), options: options,
                                       multiline: field.type == "textarea", saveKey: key, isCheckbox: false))
            }
        }
        if stillAsk.map(\.id) != asks.map(\.id) { asks = stillAsk }
    }

    private func fill(_ field: PageScan.Field, _ value: String, label: String) async {
        handled[field.id] = value
        let js = "window.__doorlist.fill(\(Self.jsString(field.id)), \(Self.jsString(value)))"
        if (try? await webView?.evaluateJavaScript(js)) as? Bool == true {
            filledCount += 1
            let shown = field.type == "checkbox" ? "Agreed" : value
            sent[field.id] = SentAnswer(question: Self.cleanLabel(label), answer: shown)
            phase = .working("Filled \(filledCount) from memory")
        }
    }

    /// Taps whatever moves the booking forward: RSVP / Register first, then the
    /// form's own Continue / Submit. Never a button that names a price.
    private func pressNext(_ scan: PageScan) async {
        guard Date().timeIntervalSince(lastClick) > 2.2 else { return }
        let ranked = scan.buttons.compactMap { b -> (PageScan.Button, Int)? in
            Self.rank(b.text, isLink: b.isLink == true).map { (b, $0) }
        }.sorted { $0.1 < $1.1 }
        guard let (button, rank) = ranked.first(where: { (clicks[Self.norm($0.0.text)] ?? 0) < 2 }) else {
            if case .working = phase, Date().timeIntervalSince(startedAt) > 20 {
                phase = .needsYou("Tap the button on the page to finish")
            }
            return
        }
        clicks[Self.norm(button.text), default: 0] += 1
        lastClick = Date()
        phase = .working(rank >= 100 ? "Sending your answers" : "Tapping \(button.text)")
        _ = try? await webView?.evaluateJavaScript("window.__doorlist.click(\(Self.jsString(button.id)))")
    }

    // MARK: The person answers

    func answer(_ ask: WebAsk, value: String, remember: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if remember, !ask.isCheckbox, !ask.saveKey.isEmpty {
            AnswerStore.shared.set(ask.saveKey, label: ask.label, value: trimmed)
        }
        if ask.isCheckbox, remember { Preferences.autoAgree = true }
        asks.removeAll { $0.id == ask.id }
        let field = lastScan?.fields.first { $0.id == ask.id }
        Task {
            if let field {
                await fill(field, trimmed, label: ask.label)
            } else {
                handled[ask.id] = trimmed
                _ = try? await webView?.evaluateJavaScript(
                    "window.__doorlist.fill(\(Self.jsString(ask.id)), \(Self.jsString(trimmed)))")
            }
            await tick()
        }
    }

    // MARK: Finishing

    private func finish(_ status: BookingStatus, alreadyBooked: Bool) {
        guard !finished else { return }
        finished = true
        stop()
        learnTypedAnswers()
        let record = BookingRecord(
            id: link.url.absoluteString, eventName: eventTitle ?? link.url.host ?? "Event",
            url: link.url.absoluteString, status: status,
            startAt: lastScan?.start.flatMap(Self.date), bookedAt: Date(),
            coverUrl: lastScan?.image, place: lastScan?.place,
            answers: Array(sent.values), platform: platform)
        let known = HistoryStore.shared.all().contains { $0.id == record.id }
        if !alreadyBooked || !known { HistoryStore.shared.add(record) }
        if !alreadyBooked {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Notifier.booked(record.eventName, status: status, platform: platform, url: link.url)
        }
        phase = .done(status, alreadyBooked: alreadyBooked)
    }

    /// Answers the person typed straight into the page are remembered too.
    private func learnTypedAnswers() {
        guard let scan = lastScan else { return }
        let saved = AnswerStore.shared.all()
        for field in scan.fields where handled[field.id] == nil && field.type != "checkbox" && field.type != "radio" {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !field.label.isEmpty, field.options == nil else { continue }
            let key = Self.key(for: field, saved: saved)
            if saved[key] == nil { AnswerStore.shared.set(key, label: Self.cleanLabel(field.label), value: value) }
        }
    }

    // MARK: Matching

    /// Which remembered answer a page field wants: the browser autofill hint
    /// first, then the same wording rules Luma questions use.
    static func key(for field: PageScan.Field, saved: [String: SavedAnswer]) -> String {
        switch field.autocomplete {
        case "given-name": return "first_name"
        case "family-name": return "last_name"
        case "name": return "name"
        case "email": return "email"
        case "tel", "tel-national": return "phone"
        case "organization": return "company"
        case "organization-title": return "job_title"
        default: break
        }
        let label = cleanLabel(field.label)
        let n = QuestionMatcher.normalize(label + " " + field.name.replacingOccurrences(of: "_", with: " "))
        if field.type == "email" || n.range(of: #"\be ?mail\b"#, options: .regularExpression) != nil,
           n.range(of: #"\b(work|business|company)\b"#, options: .regularExpression) == nil { return "email" }
        if field.type == "tel" { return "phone" }
        if n.range(of: #"\b(first name|given name|firstname|fname)\b"#, options: .regularExpression) != nil { return "first_name" }
        if n.range(of: #"\b(last name|surname|family name|lastname|lname)\b"#, options: .regularExpression) != nil { return "last_name" }
        if n.range(of: #"^(full )?name\b|\byour name\b|\bfull name\b"#, options: .regularExpression) != nil { return "name" }
        if let rule = QuestionMatcher.ruleKey(for: label) { return rule }
        let own = QuestionMatcher.labelKey(for: label)
        if saved[own] != nil { return own }
        return QuestionMatcher.closestSavedKey(for: label, in: saved) ?? own
    }

    static func value(for key: String, saved: [String: SavedAnswer]) -> String? {
        if let answer = saved[key], !answer.value.isEmpty { return answer.choices?.first ?? answer.value }
        let full = saved["name"]?.value
        switch key {
        case "first_name":
            return full.map { BookingPlanner.splitName($0).first }.flatMap { $0.isEmpty ? nil : $0 }
        case "last_name":
            return full.map { BookingPlanner.splitName($0).last }.flatMap { $0.isEmpty ? nil : $0 }
        case "name":
            guard let first = saved["first_name"]?.value else { return nil }
            return [first, saved["last_name"]?.value ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        default:
            return nil
        }
    }

    private static let entryWords = ["rsvp", "going", "i'm going", "im going", "register", "get tickets", "get ticket",
                                     "reserve a spot", "reserve", "request to join", "join waitlist",
                                     "join the waitlist", "attend", "count me in", "join event", "sign up for event",
                                     "apply now", "apply to attend", "apply to join", "apply to hack", "request invite"]
    /// Matched only exactly, so "Apply coupon" or "Apply code" is never tapped.
    private static let exactEntryWords: Set<String> = ["apply"]
    /// Links are only followed for these; "Sign up" or "Join" links in a site's
    /// header make an account, not a booking.
    private static let linkEntryWords: Set<String> = ["rsvp", "register", "get tickets", "get ticket", "reserve a spot"]
    private static let submitWords = ["submit", "continue", "next", "confirm", "done", "complete registration",
                                      "register now", "complete", "save", "send", "rsvp now", "place order",
                                      "complete order", "checkout", "check out", "get my ticket", "submit rsvp"]
    private static let never = ["can't", "cant", "not going", "maybe", "decline", "no", "cancel", "back", "share",
                                "accept", "reject", "cookie", "allow",
                                "log out", "sign out", "delete", "remove", "pay", "buy", "add to calendar",
                                "follow", "message", "contact", "report", "invite", "host", "create"]

    /// Lower is tapped first; nil means never tap it. Submit buttons rank 100+.
    static func rank(_ raw: String, isLink: Bool) -> Int? {
        let t = norm(raw)
        if never.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return nil }
        if ["$", "€", "£", "₹"].contains(where: t.contains) { return nil }
        if let i = submitWords.firstIndex(of: t) { return isLink ? nil : 100 + i }
        if exactEntryWords.contains(t) { return isLink ? nil : entryWords.count }
        if let i = entryWords.firstIndex(where: { t == $0 || t.hasPrefix($0 + " ") }) {
            return !isLink || linkEntryWords.contains(entryWords[i]) ? i : nil
        }
        return nil
    }

    private static let confirmations: [(status: BookingStatus, phrases: [String])] = [
        (.waitlist, ["you're on the waitlist", "you are on the waitlist", "added to the waitlist", "joined the waitlist"]),
        (.pendingApproval, ["request sent", "pending approval", "awaiting approval", "your request has been sent",
                            "the host will review", "request submitted"]),
        (.approved, ["you're going", "you are going", "you're on the list", "you're registered", "you are registered",
                   "you're in!", "rsvp confirmed", "order confirmed", "thanks for your order", "thank you for your order",
                   "thanks for registering", "thank you for registering", "registration confirmed",
                     "you're all set", "see you there", "check your email for your ticket", "you rsvp'd going"]),
    ]

    /// Every confirmation phrase on the page, waitlist and pending first.
    static func successPhrases(in text: String) -> [(status: BookingStatus, phrase: String)] {
        confirmations.flatMap { group in group.phrases.filter(text.contains).map { (group.status, $0) } }
    }

    /// A non-zero total on the page means money; Doorlist stops there.
    static func looksPaid(_ text: String) -> Bool {
        let pattern = #"(order total|total|subtotal|amount due)\s*:?\s*(us)?[$€£₹]\s?([0-9]+(?:[.,][0-9]{2})?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let amount = Double(ns.substring(with: m.range(at: 3)).replacingOccurrences(of: ",", with: ".")) ?? 0
            if amount > 0 { return true }
        }
        return false
    }

    static func isPlaceholderOption(_ s: String) -> Bool {
        let n = norm(s)
        return n.hasPrefix("select") || n.hasPrefix("choose") || n.isEmpty || n == "please select"
    }

    static func cleanLabel(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\*\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(required\)\s*"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}'$€£₹ ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func tidyTitle(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[|·–-]\s*(Partiful|Eventbrite)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+Tickets?,.*$"#, with: "", options: .regularExpression)
    }

    nonisolated static func date(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let d = local.date(from: raw) { return d }
        }
        return nil
    }

    /// A Swift string as a JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

// MARK: - Screen

/// Books on the event's own page: Doorlist fills and taps while the person
/// watches, and they can take over at any point.
struct WebBookingView: View {
    @StateObject private var model: WebBookingModel
    let onClose: () -> Void
    @State private var answerText = ""
    @State private var remember = true
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(link: EventLink, promoCode: String? = nil, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: WebBookingModel(link: link, promoCode: promoCode))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .opacity(model.progress > 0 && model.progress < 1 ? 1 : 0)
                EventPageWebView(model: model)
            }
            .overlay(alignment: .bottom) {
                if let ask = model.asks.first, !isDone { askPanel(ask) }
            }
            .overlay { if case .done(let status, let already) = model.phase { doneCard(status, already) } }
            .animation(Theme.spring, value: model.asks)
            .animation(Theme.spring, value: model.phase)
            .navigationTitle(model.eventTitle ?? (model.platform == .web ? "Event" : model.platform.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) }
                ToolbarItem(placement: .primaryAction) {
                    if case .paused = model.phase {
                        Button("Resume") { model.resume() }
                    } else if !isDone {
                        Button("Let me") { model.pause() }
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { notifyFirstAsk() }
            if phase == .background, model.needsRobotCheck { Notifier.robotCheck(event: model.eventTitle) }
            if phase == .active { Notifier.clearQuestion() }
        }
        .onChange(of: model.asks) { _, _ in if scenePhase != .active { notifyFirstAsk() } }
        .onChange(of: model.needsRobotCheck) { _, waiting in
            if waiting, scenePhase != .active { Notifier.robotCheck(event: model.eventTitle) }
            if !waiting { Notifier.clearRobotCheck() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AnswerInbox.name)) { note in
            guard let (token, text) = AnswerInbox.read(note), let ask = model.asks.first(where: { $0.id == token }) else { return }
            var value = text
            if let options = ask.options, !options.isEmpty { value = QuestionMatcher.choose(text, from: options) ?? "" }
            if ask.isCheckbox { value = "true" }
            Notifier.clearQuestion()
            if !value.isEmpty { model.answer(ask, value: value, remember: true) }
        }
    }

    private var isDone: Bool { if case .done = model.phase { true } else { false } }

    private func notifyFirstAsk() {
        guard let ask = model.asks.first, !isDone else { return }
        Notifier.needsAnswer(ask.isCheckbox ? "Agree to the event's terms?" : ask.label,
                             event: model.eventTitle, token: ask.id, choices: ask.options)
    }

    private var statusBar: some View {
        let (symbol, tint, text): (String, Color, String) = switch model.phase {
        case .working(let t): ("sparkles", .accentColor, t)
        case .needsYou(let t): ("hand.point.up.left.fill", .orange, t)
        case .paid: ("creditcard.fill", .orange, "This one costs money. Check it and pay on the page yourself.")
        case .paused: ("pause.circle.fill", .secondary, model.pausedNote ?? "You're driving. Doorlist is watching for the confirmation.")
        case .done: ("checkmark.circle.fill", .green, "Done")
        }
        let steering: Bool = switch model.phase {
        case .paused, .needsYou, .paid: true
        default: false
        }
        return HStack(spacing: 10) {
            Label {
                Text(text).font(.footnote.weight(.medium)).foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if steering {
                // The person is on the page: one tap puts in everything Doorlist knows.
                Button {
                    Task { await model.fillNow() }
                } label: {
                    Label("Fill this page", systemImage: "wand.and.sparkles")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Fills every field Doorlist has an answer for. Nothing is sent.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private func askPanel(_ ask: WebAsk) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ask.isCheckbox ? "One quick yes" : ask.label)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if ask.isCheckbox {
                Text(ask.label).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                Toggle("Agree to event terms for me from now on", isOn: $remember)
                    .font(.footnote).tint(.accentColor)
                Button("Agree") { model.answer(ask, value: "true", remember: remember) }
                    .buttonStyle(.primary)
            } else if let options = ask.options, !options.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { model.answer(ask, value: option, remember: remember) }
                                .buttonStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 220)
                rememberToggle
            } else {
                HStack(spacing: 8) {
                    TextField("Type or tap the mic", text: $answerText, axis: ask.multiline ? .vertical : .horizontal)
                        .lineLimit(ask.multiline ? 3...6 : 1...1)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { submit(ask) }
                        .padding(.vertical, 12)
                    MicButton(context: ask.label, into: $answerText, append: ask.multiline)
                }
                .padding(.leading, 12).padding(.trailing, 4)
                .background(Color.fill,
                            in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                rememberToggle
                if ask.multiline {
                    AIWriteBar(question: ask.label, text: $answerText)
                        .environment(\.draftContext, DraftContext(event: model.eventTitle, about: model.pageText))
                }
                Button("Fill it in") { submit(ask) }
                    .buttonStyle(.primary)
                    .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(12)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .id(ask.id)
        .onAppear {
            answerText = ""
            remember = true
            focused = (ask.options?.isEmpty ?? true) && !ask.isCheckbox
        }
    }

    private var rememberToggle: some View {
        Toggle(isOn: $remember) {
            Label("Remember for next time", systemImage: "brain").font(.footnote).foregroundStyle(.secondary)
        }
        .tint(.accentColor)
    }

    private func submit(_ ask: WebAsk) {
        model.answer(ask, value: answerText, remember: remember)
        answerText = ""
    }

    private func doneCard(_ status: BookingStatus, _ already: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: status.symbol)
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(status.tint)
                    .accessibilityHidden(true)
                Text(already ? "Already on the list" : status == .approved ? "You're in" : status.title)
                    .font(.title.weight(.bold))
                if let title = model.eventTitle {
                    Text(title).font(.headline).multilineTextAlignment(.center)
                }
                Text(already ? "You already have a spot for this one."
                     : "Booked on \(model.platform.name). Doorlist filled \(model.filledCount) answers for you.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Done", action: onClose).buttonStyle(.primary).padding(.top, 6)
            }
            .padding(24)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(24)
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity)
    }
}

/// The in-app browser. Uses the default data store, so a Partiful or Eventbrite
/// sign-in made once stays signed in for every later booking.
private struct EventPageWebView: UIViewRepresentable {
    let model: WebBookingModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Safari's own wording, with this phone's real iOS version: a mismatched one looks off to sites
        // and brings more robot checks.
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "26"
        config.applicationNameForUserAgent = "Version/\(major).0 Mobile/15E148 Safari/604.1"
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.uiDelegate = context.coordinator
        model.webView = view
        context.coordinator.progress = view.observe(\.estimatedProgress) { [weak model] web, _ in
            let value = web.estimatedProgress
            Task { @MainActor in model?.progress = value }
        }
        view.load(URLRequest(url: model.link.url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        var progress: NSKeyValueObservation?

        /// target=_blank links and window.open load here, in the same page, instead of going nowhere.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
