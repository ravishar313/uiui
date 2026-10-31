"""Synthetic prose-number sentences for TTS (no LLM). Writes {id,text,speak,mix,terms,ntype}.
Convention (derived from eval-ref style statistics, see report): digits for clock times / years / dates / ordinals (glued 11th) / money (₹ prefix) /
percent ("12 percent") / versions / Q3 / ids / decimals / units (spaced) / prose-word+number (spaced: "page 12", "net 30").
Small counts 1-10 before a unit noun are mostly spelled out (eval refs: 45 words vs 6 digits) -> 70% words, 30% digits here.
"""
import json, random, re, sys, collections
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 7
R = random.Random(seed)
TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 7400

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
def w(n):
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000: return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + w(n % 100))
    if n < 100000: return w(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + w(n % 1000))
    raise ValueError
def digs(s): return " ".join("zero" if R.random() < .6 else "oh" if c == "0" else ONES[int(c)] for c in s) if False else " ".join(ONES[int(c)] if c != "0" else R.choice(["zero", "zero", "oh"]) for c in s)
def dec(s):  # "2.5" -> two point five
    a, b = s.split("."); return w(int(a)) + " point " + " ".join(ONES[int(c)] for c in b)
ORD = {1: "first", 2: "second", 3: "third", 5: "fifth", 8: "eighth", 9: "ninth", 12: "twelfth"}
def ordw(n):
    if n in ORD: return ORD[n]
    if n < 20: return ONES[n] + "th"
    if n % 10 == 0: return w(n)[:-1] + "ieth"
    return w(n - n % 10) + " " + ordw(n % 10)
def osuf(n): return "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
def yearw(y):
    if y < 2000: return w(y // 100) + (" hundred" if y % 100 == 0 else " " + ("oh " + ONES[y % 100] if y % 100 < 10 else w(y % 100)))
    if y < 2010: return "two thousand" + ("" if y == 2000 else R.choice([" ", " and "]) + ONES[y - 2000])
    return R.choice(["twenty " + w(y - 2000), "two thousand " + w(y - 2000)]) if y < 2020 else R.choice(["twenty " + w(y - 2000), "twenty " + w(y - 2000), "two thousand " + w(y - 2000)])
MONTHS = "January February March April May June July August September October November December".split()
MAB = {"January": "Jan", "February": "Feb", "March": "Mar", "April": "Apr", "June": "Jun", "July": "Jul", "August": "Aug", "September": "Sep", "October": "Oct", "November": "Nov", "December": "Dec"}
HIN = "_ ek do teen char paanch chhah saat aath nau das gyarah barah".split()

# ---------------- number slots: each returns (text, speak) ----------------
def s_hr(): h = R.choice([1,2,3,4,5,6,7,8,9,10,11,12,12,10,9,8,5,4,3,2]); return str(h), w(h)
def s_hrh():
    h = R.choice(range(1, 13)); return str(h), (HIN[h] if R.random() < .75 else w(h))
def s_time():
    h = R.randint(1, 12); m = R.choice([0, 0, 5, 10, 15, 15, 20, 25, 30, 30, 30, 40, 45, 45, 50, 55]); ap = R.choice(["am", "pm"])
    r = R.random()
    def mw(m): return "" if m == 0 else (("oh " + ONES[m]) if m < 10 else w(m))
    if r < .35: return f"{h} {ap}", f"{w(h)} {'A M' if ap=='am' else 'P M'}"
    if r < .85 or m == 0:
        if m == 0: return f"{h} {ap}", f"{w(h)} {'A M' if ap=='am' else 'P M'}"
        return f"{h}:{m:02d} {ap}", f"{w(h)} {mw(m)} {'A M' if ap=='am' else 'P M'}"
    if m == 0: m = 30
    return f"{h}:{m:02d}", f"{w(h)} {mw(m)}"
def s_time24():
    h = R.choice([9, 10, 11, 14, 15, 16, 17, 18, 8, 7]); m = R.choice([0, 15, 30, 45, 10, 20, 40, 50]);
    if m == 0: return f"{h}:00", f"{w(h)} hundred hours" if h > 12 else f"{w(h)} o'clock"
    return f"{h}:{m:02d}", f"{w(h)} {w(m)}"
def s_year():
    y = R.choice([R.randint(1900, 1999)] * 4 + [R.randint(2000, 2029)] * 5 + [R.choice([1947, 1950, 1971, 1984, 1991, 1999, 2000, 2008, 2014, 2020])]); return str(y), yearw(y)
def s_my():
    m = R.choice(MONTHS); y = R.randint(1988, 2027); return f"{m} {y}", f"{m} {yearw(y)}"
def s_dm():
    d = R.randint(1, 31); m = R.choice(MONTHS)
    if m == "May" or R.random() < .5: mt = m
    else: mt = MAB[m]
    return f"{d}{osuf(d)} {mt}", f"{ordw(d)} {m}"
def s_dmy():
    d = R.randint(1, 31); m = R.choice(MONTHS); y = R.randint(1985, 2027)
    if R.random() < .4: return f"{d}{osuf(d)} of {m} {y}", f"{ordw(d)} of {m} {yearw(y)}"
    return f"{d}{osuf(d)} {m} {y}", f"{ordw(d)} {m} {yearw(y)}"
def s_md():
    d = R.randint(1, 31); m = R.choice(MONTHS); return f"{m} {d}", f"{m} {ordw(d)}" if R.random() < .5 else f"{m} {w(d)}"
def s_ord():
    n = R.choice(list(range(2, 31)) + [40, 50, 100, 11, 12, 13, 21, 22, 23]); return f"{n}{osuf(n)}", ordw(n)
def s_dayn():
    n = R.randint(1, 31); return f"{n}{osuf(n)}", ordw(n)
def s_decade():
    d = R.choice([1950, 1960, 1970, 1980, 1990, 2000, 2010]); sp = {1950: "fifties", 1960: "sixties", 1970: "seventies", 1980: "eighties", 1990: "nineties", 2000: "two thousands", 2010: "twenty tens"}
    return f"{d}s", f"nineteen {sp[d]}" if d < 2000 and d != 1950 and False else (("nineteen " + sp[d]) if d < 2000 else sp[d])
def _cnt(n, noun, p_word=.7):
    if n <= 10 and R.random() < p_word: return f"{w(n)} {noun}", f"{w(n)} {noun}"
    if 11 <= n <= 20 and R.random() < .15: return f"{w(n)} {noun}", f"{w(n)} {noun}"
    return f"{n} {noun}", f"{w(n)} {noun}"
def _sing(n, noun): return noun[:-1] if n == 1 and noun.endswith("s") else noun
def s_dur():
    n = R.choice([1,2,2,3,3,3,4,5,5,6,7,8,10,10,12,14,15,20,24,30,45,48,60,90]); u = R.choice(["days", "days", "weeks", "months", "years", "hours", "minutes", "mins", "weeks", "hours"])
    if u == "mins" and n < 10: n = R.choice([10, 15, 20, 5])
    return _cnt(n, _sing(n, u))
def s_dur_digit():  # forced digits ("for 3 days")
    n = R.choice([2,3,3,4,5,6,7,8,9,10,12,15,20,30,45]); u = R.choice(["days", "weeks", "months", "hours", "minutes", "years"]); return f"{n} {u}", f"{w(n)} {u}"
def s_cobj():
    n = R.choice([2,3,4,5,6,7,8,9,10,11,12,14,15,16,18,20,25,30,40,50,60,100,120,150,200,250,300,500,800]); u = R.choice("people tickets files lines members items rows servers candidates clients invoices bugs slides users devices".split()); return _cnt(n, u)
def s_pn():
    n = R.choice(list(range(1, 40)) + [R.randint(40, 400)] * 3); return str(n), w(n)
def s_net():
    n = R.choice([7, 10, 15, 30, 45, 60, 90]); return str(n), w(n)
def s_room():
    n = R.choice([R.randint(101, 999), R.randint(11, 99), R.randint(1001, 1999)]);
    sp = " ".join(ONES[int(c)] for c in str(n)) if R.random() < .35 else (w(n) if n < 1000 else w(n // 100) + " hundred " + w(n % 100) if n % 100 else w(n))
    sp = sp.replace(" hundred zero", " hundred")
    return str(n), sp
def _comma(n):
    return f"{n:,}"
def s_inr():
    r = R.random()
    if r < .22: n = R.randint(1, 9); return f"₹{n} lakh", f"{w(n)} lakh rupees"
    if r < .40: d = R.randint(1, 9); f = R.randint(1, 9); return f"₹{d}.{f} lakh", f"{dec(f'{d}.{f}')} lakh rupees"
    if r < .52: n = R.choice([10, 12, 15, 18, 20, 25, 30, 40, 45, 50, 60, 75, 80]); return f"₹{n} lakh", f"{w(n)} lakh rupees"
    if r < .64: n = R.choice([1, 2, 3, 4, 5, 8, 10, 12, 20, 25, 50, 100, 200]); return f"₹{n} crore", f"{w(n)} crore rupees"
    if r < .70: d = R.randint(1, 9); f = R.randint(1, 9); return f"₹{d}.{f} crore", f"{dec(f'{d}.{f}')} crore rupees"
    if r < .84: n = R.choice([1500, 2000, 2500, 3000, 4500, 5000, 7500, 8000, 9500, 12000, 15000, 18000, 20000, 25000, 30000, 35000, 40000, 45000, 50000, 75000, 85000]); return f"₹{_comma(n)}", f"{w(n)} rupees"
    if r < .92: n = R.choice([99, 199, 250, 299, 350, 450, 499, 500, 600, 750, 899, 999]); return f"₹{n}", f"{w(n)} rupees"
    n = R.choice([1200, 1800, 2200, 4999, 3500, 6500]); return f"₹{_comma(n)}", f"{w(n)} rupees"
def s_inr_h():  # hinglish
    t, s = s_inr(); return t, s
def s_usd():
    r = R.random()
    if r < .4: n = R.choice([50, 100, 150, 200, 250, 300, 500, 800]); return f"${n}", f"{w(n)} dollars"
    if r < .7: n = R.choice([1200, 2500, 3000, 4500, 5000, 10000, 15000, 20000, 50000]); return f"${_comma(n)}", f"{w(n)} dollars"
    n = R.choice([1, 2, 3, 5, 10, 20, 50]); u = R.choice(["million", "million", "billion"]); return f"${n} {u}", f"{w(n)} {u} dollars"
def s_pct():
    r = R.random()
    if r < .45:
        n = R.randint(1, 10)
        if R.random() < .5: return f"{w(n)} percent", f"{w(n)} percent"
        return f"{n} percent", f"{w(n)} percent"
    if r < .82: n = R.choice(list(range(11, 100)) + [100, 100]); return f"{n} percent", f"{w(n)} percent"
    if r < .97: d = R.randint(1, 30); f = R.randint(1, 9); return f"{d}.{f} percent", f"{dec(f'{d}.{f}')} percent"
    a = R.randint(5, 20); b = a + R.randint(2, 10); return f"{a} to {b} percent", f"{w(a)} to {w(b)} percent"
def s_pct_big():
    n = R.choice([5, 8, 10, 12, 15, 18, 20, 25, 30, 35, 40, 50, 60, 75, 80, 90]); return f"{n} percent", f"{w(n)} percent"
def s_ver():
    r = R.random()
    if r < .3: a, b = R.randint(1, 9), R.randint(0, 12); return f"{a}.{b}", f"{w(a)} point {w(b)}"
    if r < .5: a, b, c = R.randint(1, 5), R.randint(0, 9), R.randint(0, 9); return f"{a}.{b}.{c}", f"{w(a)} point {w(b)} point {w(c)}"
    if r < .75: a = R.randint(2, 20); return f"v{a}", f"V {w(a)}"
    a = R.randint(2, 18); return f"{a}", w(a)
def s_ver_sw():
    n = R.choice([("Python", "3.{}", 6, 12), ("Node", "{}", 14, 22), ("iOS", "{}", 14, 18), ("Android", "{}", 10, 15), ("Java", "{}", 8, 21), ("Windows", "{}", 10, 11), ("Postgres", "{}", 11, 16), ("Angular", "{}", 12, 18), ("React", "{}", 16, 19), ("Ubuntu", "{}.04", 18, 24)])
    v = R.randint(n[2], n[3]); t = n[1].format(v);
    if t.startswith("3."): sp = "three point " + w(v)
    elif t.endswith(".04"): sp = w(v) + " point oh four"
    else: sp = w(v)
    return f"{n[0]} {t}", f"{n[0]} {sp}"
def s_qtr():
    q = R.randint(1, 4); r = R.random()
    if r < .7: return f"Q{q}", f"Q {w(q)}"
    y = R.randint(2022, 2027);
    if r < .85: return f"Q{q} {y}", f"Q {w(q)} {yearw(y)}"
    return f"FY{y % 100}", f"F Y {w(y % 100)}"
def s_unit():
    r = R.random()
    if r < .2: n = R.choice([2, 5, 8, 10, 12, 15, 20, 25, 40, 50, 120]); return f"{n} km", f"{w(n)} kilometres"
    if r < .5: n = R.choice([4, 8, 16, 32, 64, 128, 256, 500]); u = R.choice(["GB", "GB", "MB", "TB"]); return f"{n} {u}", f"{w(n)} {' '.join(u)}"
    if r < .62: n = R.choice([2, 5, 10, 20, 50, 100]); return f"{n} kg", f"{w(n)} kilos"
    if r < .78: n = R.choice([100, 200, 250, 300, 500]); return f"{n} ms", f"{w(n)} milliseconds"
    if r < .9: d = R.randint(1, 9); f = R.randint(1, 9); u = R.choice(["GB", "hours", "km", "metres", "MB"]); su = {"GB": "G B", "MB": "M B", "km": "kilometres"}.get(u, u); return f"{d}.{f} {u}", f"{dec(f'{d}.{f}')} {su}"
    n = R.choice([50, 100, 200]); return f"{n} Mbps", f"{w(n)} M B P S"
def s_rng():
    r = R.random()
    if r < .3: a = R.choice([2, 3, 5, 10, 15, 20]); b = a + R.choice([2, 3, 5, 10]); return f"{a} to {b}", f"{w(a)} to {w(b)}"
    if r < .5: a = R.choice([9, 10, 11]); b = R.choice([5, 6, 1, 2, 4]); return f"{a} to {b}", f"{w(a)} to {w(b)}"
    if r < .7: a = R.randint(2015, 2024); return f"{a} to {a+1}", f"{yearw(a)} to {yearw(a+1)}"
    if r < .85: a = R.choice([100, 200, 500, 1000]); b = a * R.choice([2, 5]); return f"{a} to {b}", f"{w(a)} to {w(b)}"
    a = R.choice([3, 5, 10, 20]); b = a + R.choice([5, 10, 15]); return f"{a}-{b}", f"{w(a)} to {w(b)}"
def s_between():
    a = R.choice([9, 10, 11, 2, 3, 4]); b = a + R.choice([1, 2]); b = b if b <= 12 else b - 12; return f"{a} and {b}", f"{w(a)} and {w(b)}"
def s_id():
    r = R.random()
    if r < .3: n = "".join(R.choice("0123456789") for _ in range(4)); return n, digs(n)
    if r < .55: n = "".join(R.choice("0123456789") for _ in range(6)); return n, digs(n)
    if r < .75: n = str(R.randint(100000, 999999)); return n, digs(n)
    if r < .9: n = str(R.choice([6, 7, 8, 9])) + "".join(R.choice("0123456789") for _ in range(9)); return n, digs(n)
    n = str(R.randint(1, 9)) + "".join(R.choice("0123456789") for _ in range(4)); return n, digs(n)
def s_pin():
    n = str(R.choice([5, 6])) + "".join(R.choice("0123456789") for _ in range(5)); return n, digs(n)
def s_dec():
    d = R.randint(0, 20); f = R.randint(1, 99) if R.random() < .3 else R.randint(1, 9); t = f"{d}.{f}"; return t, dec(t) if f < 10 else (w(d) + " point " + " ".join(ONES[int(c)] for c in str(f)))
def s_k():  # 5k, 10 thousand
    n = R.choice([2, 3, 5, 10, 15, 20, 50]); return f"{n}k", f"{w(n)} K"
def s_bignum():
    n = R.choice([1200, 2500, 3400, 4800, 5600, 7200, 8500, 9300, 12000, 15000, 18500, 24000, 36000, 42000, 60000, 85000, 96000]); return _comma(n), w(n)
def s_lakh_n():
    d = R.randint(1, 9); f = R.randint(1, 9); return (f"{d}.{f} lakh", f"{dec(f'{d}.{f}')} lakh") if R.random() < .5 else (f"{R.randint(2, 40)} lakh", None)
def s_hdays():  # hinglish "din"
    n = R.choice([2, 3, 3, 4, 5, 5, 6, 7, 10, 10, 15, 20, 30]); hw = {2: "do", 3: "teen", 4: "char", 5: "paanch", 6: "chhah", 7: "saat", 10: "das"}
    if n in hw and R.random() < .5: return f"{n}", hw[n]
    return f"{n}", w(n) if n not in hw or True else hw[n]
def s_hh():
    n = R.randint(2, 30); return str(n), w(n)
def s_pgn():
    n = R.randint(2, 99); return str(n), w(n)

SLOTS = {k[2:]: v for k, v in globals().items() if k.startswith("s_")}

# ---------------- vocab ----------------
NAMES = "Rohan Priya Arjun Neha Vikram Anjali Karthik Divya Sanjay Meera Rahul Pooja Aditya Kavya Nitin Ritu Suresh Ananya Imran Farah Gaurav Shweta Deepak Lakshmi Manoj Tanvi Harish Isha Varun Swati".split()
DAYS = "Monday Tuesday Wednesday Thursday Friday Saturday Sunday".split()
CITIES = "Bengaluru Mumbai Delhi Pune Chennai Hyderabad Kolkata Gurugram Noida Ahmedabad Jaipur Kochi".split()
TOPIC = "the budget review|the vendor contract|the product roadmap|the hiring plan|the client demo|the audit report|the onboarding session|the quarterly review|the release plan|the training workshop|the sales forecast|the migration|the compliance check|the design review|the town hall|the board update|the incident review|the API rollout|the pricing proposal|the support handover".split("|")
THING = "invoice|purchase order|laptop|ticket|report|proposal|dashboard|deck|server|build|pipeline|contract|spreadsheet|dataset|camera|app|vendor quote|travel claim|reimbursement|salary slip".split("|")
TEAM = "finance|sales|design|support|platform|data|HR|operations|marketing|legal|QA|backend".split("|")
SUBJ = "the kids|my sister|our driver|the cab|the delivery|the vendor|the client|my manager|the landlord|the bank|the auditor|the courier|our flight|the train|the doctor".split("|")
PLACE = "the office|the airport|the station|the clinic|the bank|the campus|the warehouse|home|the venue|the client site".split("|")
FOOD = "lunch|dinner|breakfast|tea|coffee|the offsite|the standup|the demo|the call|the interview".split("|")
VERB = "reach|finish|send|submit|ping|share|review|approve|deploy|close|wrap up|start".split("|")
OPEN = ["", "", "", "", "", "Hi {name}, ", "Quick update: ", "Just a reminder, ", "By the way, ", "Heads up, ", "{name}, ", "Honestly, ", "Okay so ", "FYI, ", "Sorry for the delay, ", "As discussed, ", "Hey, ", "Please note, ", "Remember, ", "So basically "]
CLOSE = ["", "", "", "", "", "", " Let me know.", " Thanks.", " Please confirm.", " Does that work?", " Sounds good?", " I will follow up.", " Ping me if anything changes.", " Thanks a lot.", " That is all from my side.", " Please plan accordingly.", " We can discuss tomorrow."]

# ---------------- English templates by type ----------------
EN = {
"hour": [
 "Let's catch up at {hr} tomorrow.", "The call is at {hr}, so please join on time.", "I will reach the office by {hr}.", "The cab will pick you up around {hr}.",
 "Can we move the standup to {hr}?", "{name} said the meeting starts at {hr} sharp.", "Dinner is at {hr}, and we are booking the table.", "Please be at {place} by {hr}.",
 "We usually wrap up by {hr} on {day}.", "The delivery is expected by {hr} tonight.", "I am free after {hr} today.", "The bank closes at {hr}, so go before that.",
 "Let's meet at {hr} near {place}.", "Our flight is at {hr}, so we should leave early.", "The webinar begins at {hr} and runs for an hour.", "Can you send the {thing} before {hr}?",
 "I usually log off at {hr}.", "The shuttle leaves at {hr} from {place}.", "The doctor said to come in at {hr}.", "{topic} is scheduled for {hr} on {day}.".replace("{topic}", "{Topic}"),
 "Everyone should be online by {hr} for {topic}.", "It was already {hr} when {name} called me.", "Wake me up at {hr}, I have an early train.", "We are starting {topic} at {hr} this {day}.",
 "The {hr} o'clock bus is always full.", "I always take the {hr} o'clock train to {city}.", "Join the {hr} o'clock call if you can.",
],
"time": [
 "The meeting moved to {time} because the client is late.", "Please join {topic} at {time} on {day}.", "My flight lands at {time}, so don't wait for me.", "The deadline is {day} at {time}.",
 "The interview is scheduled for {time} with {name}.", "We start {food} at {time} sharp.", "Our train to {city} leaves at {time}.", "{name} will present from {time} onwards.",
 "The doctor appointment is at {time} on {day}.", "Can we do a quick call at {time}?", "Doors open at {time} and the session begins soon after.", "Reach {place} before {time}, please.",
 "The server maintenance window starts at {time}.", "I booked the conference room for {time}.", "The package arrived at {time} yesterday.", "Dinner reservation is for {time}.",
 "Standup is now at {time} instead of the usual slot.", "The livestream goes live at {time}.", "I messaged you at {time} but you did not reply.", "The last bus leaves at {time}.",
 "Office hours are from {time} to {time2}.", "The workshop runs from {time} till {time2}.", "Lunch break is between {time} and {time2}.",
],
"time24": [
 "The train departs at {time24} from platform {pgn}.", "Check-in closes at {time24}, so please hurry.", "The meeting is at {time24} in room {room}.", "The shift starts at {time24} and ends late.",
 "Departure is scheduled for {time24} sharp.", "We left home at {time24} and still got stuck in traffic.",
],
"year": [
 "The company was founded in {year} in {city}.", "My father joined the bank in {year}.", "We moved to {city} in {year}.", "That policy has been in place since {year}.",
 "The building was constructed in {year}, if I remember correctly.", "I graduated in {year} and started working right away.", "The first version was released in {year}.", "She was born in {year} in a small town near {city}.",
 "The merger happened back in {year}.", "Since {year}, the team has grown from a handful to hundreds.", "Our client has been with us from {year} onwards.", "The law was amended in {year}.",
 "Records from {year} show a very different picture.", "This temple dates back to {year}.", "We last audited the books in {year}.", "In {year}, the whole industry looked different.",
 "The project began in {year} and ended in {year2}.", "Between {year} and {year2}, revenue doubled.", "It was around {year} when we first met.", "The festival has been held every year since {year}.",
 "The dam was built in {year}, long before the highway.", "{name} started the startup in {year} with two friends.",
],
"decade": [
 "My parents grew up in the {decade}.", "Those songs are from the {decade}, I think.", "The architecture is typical of the {decade}.", "He was a star in the {decade}.",
],
"my": [
 "The audit happened in {my} and nothing changed since.", "Her contract ends in {my}.", "The offer letter is dated {my}.", "We signed the lease in {my}.", "The conference is planned for {my}.",
 "Please share the invoices from {my}.", "I joined the team in {my}.", "The warranty expires in {my}.", "The report for {my} is still pending.", "Our last release was in {my}, if I recall.",
],
"dm": [
 "The deadline is {dm}, so plan accordingly.", "Please submit the form by {dm}.", "We are travelling on {dm} and coming back later.", "The event is on {dm} at {place}.", "The payment is due on {dm}.",
 "The exam is on {dm}, I think.", "Her birthday is on {dm}.", "Let's schedule the review for {dm}.", "The new policy kicks in from {dm}.", "I am on leave from {dm} to {dm2}.",
 "Registrations close on {dm}.", "Can you come on {dm}?", "The audit starts on {dm} and takes a week.", "Salary will be credited on {dm}.", "The workshop is on {dm} in {city}.",
],
"dmy": [
 "The agreement was signed on {dmy}.", "He was born on {dmy} in {city}.", "The notice is dated {dmy}.", "The certificate was issued on {dmy}.", "The case was filed on {dmy}.",
],
"md": [
 "The board meets on {md} this year.", "We launch on {md} if testing goes well.", "The camp is on {md}.",
],
"ord": [
 "Our office is on the {ord} floor.", "It is our {ord} anniversary this month.", "Salaries are credited on the {ord} of every month.", "{name} finished {ord} in the class.",
 "This is the {ord} time I am reminding you.", "The meeting is on the {ord}, not the day after.", "We came {ord} out of all the teams.", "The {ord} installment is due next week.",
 "Please see the {ord} paragraph of the contract.", "It was the {ord} edition of the summit.", "Turn left at the {ord} signal.", "Her flat is on the {ord} floor of the tower.",
 "In the {ord} century, the whole region was ruled differently.", "I am attending the {ord} batch of the training.",
],
"dayn": [
 "Please clear the payment before the {dayn}.", "The rent is due on the {dayn} of each month.", "Let's catch up on the {dayn}.",
],
"cnt": [
 "I will be out for {dur} for a family function.", "The trial runs for {dur}, after which we decide.", "It took us {dur} to fix the bug.", "We waited for {dur} before anyone replied.",
 "The delivery should arrive within {dur}.", "Give me {dur} to check and I will revert.", "The meeting will take about {dur}.", "He has been on leave for {dur}.",
 "The offer is valid for {dur} only.", "The notice period is {dur}.", "Please allow {dur} for processing.", "The flight was delayed by {dur}.", "We have {dur} left before the release.",
 "The refund usually takes {dur}.", "I have been working on this for {dur}.", "The warranty covers {dur} from purchase.",
 "I will be back in {dur}.", "It is only {dur} away from {place}.",
],
"cnt_digit": [
 "We need to finish this in {dur_digit}.", "I'll be there for {dur_digit}, then travel.", "Can you cover for {dur_digit} while I am away?", "The pilot ran for {dur_digit} and went well.", "The course lasts {dur_digit}.",
 "The patient needs rest for {dur_digit}.", "Our sprint is {dur_digit} long.", "The cab was stuck for {dur_digit} on the highway.",
],
"cobj": [
 "We have {cobj} on the waiting list.", "There were {cobj} in the meeting today.", "I counted {cobj} that need approval.", "The team handled {cobj} last week.", "We are hiring {cobj} this quarter.",
 "Please review the {cobj} before Friday.", "Around {cobj} are still pending.", "We shortlisted {cobj} for the next round.", "Only {cobj} showed up for the session.", "I found {cobj} in the folder.",
 "The audit flagged {cobj} for follow-up.", "About {cobj} will join from {city}.",
],
"net": [
 "Our standard payment terms are net {net}.", "The vendor asked for net {net} terms on this order.", "Can we negotiate net {net} instead?", "We pay on net {net} terms after receiving the invoice.",
 "Finance agreed to net {net} for the first year.", "The contract says net {net}, not immediate payment.",
],
"pn": [
 "Please open page {pn} of the manual.", "Look at slide {pn} in the deck.", "The error is in line {pn} of the config file.", "We are on step {pn} of the setup.", "Read chapter {pn} before the class.",
 "Check item {pn} on the checklist.", "This is covered in section {pn} of the policy.", "{name} sits in row {pn}.", "The answer to question {pn} is wrong.", "Turn to page {pn} and read the first paragraph.",
 "The bug is described in ticket {pn}.", "We are at level {pn} of the escalation matrix.", "Take exit {pn} from the highway.", "It's in clause {pn} of the agreement.",
 "Bus number {pn} goes to {place}.", "Catch the route {pn} bus from the main gate.", "The bottleneck is in stage {pn} of the pipeline.", "Option {pn} looks cheaper than the rest.",
 "Please fix issue {pn} first.", "Gate {pn} is closed after {time}.", "Grade {pn} students will write the test.", "Tier {pn} support handles these cases.", "Batch {pn} starts next month.",
 "Check table {pn} in the appendix.", "Figure {pn} shows the trend clearly.", "Team {pn} will present first.", "Lab {pn} is booked on {day}.", "Wing {pn} is under repair.",
],
"room": [
 "The meeting is in room {room}.", "Please come to cabin {room} on the second floor.", "My flat number is {room}.", "He is staying in room {room} at the hotel.", "Seat {room} is reserved for the speaker.",
 "Flight {room} to {city} has been delayed.", "Take the lift to floor {pgn} and find room {room}.",
],
"inr": [
 "The vendor quoted {inr} for the whole project.", "We have approved a budget of {inr} for this quarter.", "The laptop costs around {inr} with the warranty.", "Finance flagged an overrun of {inr}.",
 "Her bonus came to {inr} this year.", "The rent is {inr} per month.", "We spent about {inr} on the offsite.", "The loan amount is {inr} at a fixed rate.",
 "The invoice total is {inr}, excluding GST.", "Can you approve {inr} for the training?", "The fine was {inr}.", "Our monthly cloud bill is nearly {inr}.", "The quotation of {inr} is valid for 30 days.".replace("30 days", "{dur_digit}"),
 "He paid {inr} as an advance.", "The reimbursement of {inr} will be credited soon.", "The cost came down to {inr} after the discount.", "We raised {inr} in the first round.",
 "The insurance premium is {inr} every year.", "Please transfer {inr} to the vendor account.", "The tender is worth {inr}.", "A flat in that area costs {inr}.", "The refund of {inr} is stuck.",
 "Total expenses crossed {inr} this month.", "Their pricing starts at {inr} per seat.", "The stipend is {inr} per month.", "It was priced at {inr} last year.",
],
"usd": [
 "The client agreed to pay {usd} for the pilot.", "Our AWS bill was {usd} last month.", "The license costs {usd} per year.", "We raised {usd} from a US investor.", "The flight ticket was {usd}.",
 "The contract is worth {usd}.", "Please budget {usd} for the conference.", "Their ARR crossed {usd} recently.",
],
"pct": [
 "Q3 revenue grew {pct} compared to last year.".replace("Q3", "{qtr}"), "Attrition came down by {pct} this year.", "The discount is {pct} on bulk orders.", "We saw a {pct} drop in traffic after the release.",
 "Sales are up {pct} over last month.", "The tax is deducted at {pct}.", "Nearly {pct} of the team works remotely.", "Our margin improved by {pct}.", "The interest rate is {pct} per annum.",
 "Battery is down to {pct}, so I will charge it.", "Accuracy went up by {pct} after the fix.", "Only {pct} of customers replied to the survey.", "The commission is {pct} of the order value.",
 "Server load is at {pct} right now.", "Costs went up {pct} because of the new vendor.", "We hit {pct} of the target this quarter.", "Their offer was {pct} lower than ours.",
 "The GST on this item is {pct}.", "{pct} of the tickets were closed within a day.", "The hike is {pct} this cycle.", "Occupancy was {pct} during the festival week.",
 "The market share fell to {pct}.", "Attendance has improved by {pct}.",
],
"ver": [
 "We are still running version {ver} in production.", "The bug was fixed in version {ver}.", "Please upgrade to version {ver} before Friday.", "The app is on build {pn} of version {ver}.",
 "Release {ver} goes out next week.", "The docs describe version {ver} of the API.",
],
"ver_sw": [
 "Our servers still run {ver_sw}.", "The app needs {ver_sw} or later.", "We are upgrading to {ver_sw} this month.", "It works fine on {ver_sw}.", "The build failed on {ver_sw}.",
 "Please install {ver_sw} before the workshop.", "Support for {ver_sw} ends soon.",
],
"qtr": [
 "{qtr} revenue grew {pct} year on year.", "We missed the target in {qtr} by a small margin.", "The {qtr} hiring plan is ready for review.", "Please share the {qtr} numbers by {dayn}.",
 "Marketing spend dropped in {qtr}.", "Let's review the {qtr} targets on {day}.", "The {qtr} release is delayed by {dur}.", "Sales in {qtr} crossed {inr}.", "The {qtr} roadmap has {cobj}.",
 "We closed {qtr} with {pct} growth.", "I will present the {qtr} results.",
],
"unit": [
 "The new laptop has {unit} of storage and a decent screen.".replace("{unit}", "{unit_gb}"), "The office is {unit} from the metro station.".replace("{unit}", "{unit_km}"),
 "The file is about {unit} in size.".replace("{unit}", "{unit_gb}"), "My commute is {unit_km} each way.", "The latency is around {unit_ms}.", "Our internet speed is {unit_mbps}.",
 "We ran {unit_km} this morning.", "The parcel weighs {unit_kg}.", "The backup takes about {unit_gb} of space.", "The response time dropped to {unit_ms}.",
 "The disk is full, we need another {unit_gb}.", "The venue is nearly {unit_km} away.",
],
"rng": [
 "Please keep the report between {between} pages.", "We expect {rngn} people at the event.", "The work took {rngn} days in total.", "Office timings are {rngh} on weekdays.",
 "The fiscal year is {rng} for this report.".replace("{rng}", "{rng_year}"), "The ticket price ranges from {rngn} thousand.",
 "We need {rngn} engineers for this.", "Stock was within {rngn} units all week.", "Call me between {between} if possible.", "It will cost somewhere from {rngn} lakh.", "Plan for {rngn} hours of testing.",
],
"id": [
 "My employee ID is {id}.", "Please quote reference number {id} in your mail.", "The OTP is {id}, do not share it.", "Your ticket number is {id}.", "The tracking number is {id}.",
 "Use extension {id} to reach the front desk.", "Call me on {id} if it is urgent.", "My order number is {id}.", "The case ID is {id}.", "Enter the code {id} at checkout.",
],
"pin": [
 "Our office pin code is {pin}.", "The courier is stuck at pin code {pin}.", "Please deliver it to {city}, {pin}.", "The pin code for the new branch is {pin}.",
],
"dec": [
 "The average score was {dec} out of ten.".replace("ten", "five") if False else "The average rating was {dec} stars.", "We measured {dec} on the second run.", "The ratio came out to {dec}.", "Our CGPA was {dec} at graduation.",
 "The magnitude was {dec} on the scale.", "The average basket size is {dec} items.", "The mean wait time was {dec} minutes.",
],
"k": [
 "We have about {k} followers on the page.", "The campaign reached {k} users in a week.", "Their salary is around {k} per month.".replace("around {k}", "around {k}"), "We processed {k} requests an hour.",
],
"bignum": [
 "We received {bignum} applications this year.", "The stadium holds about {bignum} people.", "The database has {bignum} records.", "Nearly {bignum} users logged in today.", "Footfall touched {bignum} on the weekend.",
 "We shipped {bignum} units last quarter.",
],
"multi": [
 "The review is on {dm} at {time}, and {name} will present.", "Our {qtr} target is {pct} higher than last year.",
 "We signed in {year}, and the contract renews in {my}.", "The {ord} installment of {inr} is due on {dm}.", "It took {dur} and cost about {inr}.",
 "Call me after {hr}, I have a {dur_digit} meeting before that.", "Revenue grew {pct} in {qtr}, reaching {inr}.", "In {year}, we had {cobj}; today we have {cobj2}.",
 "The flight leaves on {dm} at {time}.", "Join at {hr} on the {dayn}, and keep {dur} free.", "{name} moved to {city} in {year}.", "Version {ver} was released in {my}.",
 "The deadline is {dm}, and the budget is {inr}.", "Payment terms are net {net}, with a {pct} discount for early payment.", "He joined in {my} and got a {pct} hike in {year2}.",
 "The batch of {cobj} starts at {hr} on {dm}.", "Between {year} and {year2}, the team grew by {pct}.", "Room {room} is booked from {time} to {time2}.",
 "We deployed {ver_sw} on {dm} at {time}.", "Expect {dur} of downtime on {dm}.",
],
}
# Hinglish templates ({hrh} hindi words for baje)
HI = {
"hour": [
 "kal {hrh} baje meeting hai, time pe aa jana.", "{name}, call {hrh} baje rakhte hain.", "Main {hrh} baje tak office pahunch jaunga.", "cab {hrh} baje aayegi, ready rehna.",
 "har {day} {hrh} baje weekly sync hota hai.", "Aaj raat {hrh} baje tak report bhej dena.", "standup {hrh} baje shift kar do please.", "{place} pe {hrh} baje milte hain.",
 "Yaar, flight {hrh} baje ki hai, jaldi nikalna padega.", "client ka call {hrh} baje hai, sab log join karna.", "Subah {hrh} baje uthna hai kal.", "Dinner {hrh} baje tak ho jayega.",
 "kal subah {hrh} baje {topic} hai.", "mujhe {hrh} baje ke baad free samjho.", "bank {hrh} baje band ho jata hai, pehle chale jao.", "{name} ne bola ki {hrh} baje tak aa jayega.",
],
"time": [
 "kal {time} ko call hai, calendar mein daal dena.", "meeting {time} pe shift ho gayi hai.", "{name}, {day} ko {time} pe milte hain.", "Interview {time} pe hai, thoda pehle aa jana.",
 "train {time} ki hai, station pe milte hain.", "Aaj {time} ke baad mujhe call mat karna.", "demo {day} {time} pe rakha hai.", "Flight {time} pe land karegi, cab bhej dena.",
 "Client {time} tak reply karega bola hai.", "kal ka standup {time} pe rakhte hain, thoda jaldi ho jayega.",
],
"year": [
 "ye company {year} mein start hui thi.", "Main {year} mein Bangalore shift hua tha.", "{year} se hum is client ke saath kaam kar rahe hain.", "Papa ne bank {year} mein join kiya tha.",
 "ye policy {year} se lagu hai.", "meri graduation {year} mein hui thi.",
],
"dm": [
 "deadline {dm} hai, plan kar lo.", "Mera flight {dm} ko hai, leave approve kar do.", "payment {dm} tak due hai.", "Event {dm} ko {city} mein hai.", "{name} ki shaadi {dm} ko hai.",
 "Salary {dm} ko credit hogi.", "exam {dm} se start ho raha hai.",
],
"cnt": [
 "{hdays} din mein kaam khatam ho jayega.", "Main {hdays} din ke liye leave pe hoon.", "ye trial {hdays} din chalega, phir decide karenge.", "delivery {hdays} din mein aa jayegi.",
 "{hdays} din se wait kar raha hoon, abhi tak reply nahi aaya.", "{hdays} hafte lagenge ye project complete karne mein.", "bas {hdays} minute mein call karta hoon.",
 "{cobj_h} log aaye the meeting mein.", "hamare team mein abhi {cobj_h} log hain.", "{cobj_h} tickets abhi tak pending hain.",
],
"inr": [
 "vendor ne {inr} ka quote diya hai.", "budget {inr} approve ho gaya hai.", "abhi tak sirf {inr} kharch hua hai.", "laptop {inr} ka padega, approval chahiye.", "Bonus {inr} ka mila is saal.",
 "client ne {inr} ka PO bheja hai.", "ye project {inr} ka hai, dhyan se karna.", "kiraya {inr} per month hai.", "invoice {inr} ka hai, GST alag se.", "{name} ne {inr} advance de diya.",
 "Loan {inr} ka liya hai maine.", "EMI {inr} ki hai har mahine.",
],
"pct": [
 "is quarter mein sales {pct} badhi hai.", "server ka CPU {pct} par hai, dekh lo.", "discount {pct} ka mila hai.", "Attrition {pct} tak aa gaya hai.", "Target ka {pct} complete ho gaya.",
 "hike sirf {pct} mila, kya karein.", "Battery {pct} bachi hai, charger do.", "GST {pct} lagega is par.",
],
"ord": [
 "hamara office {ord} floor par hai.", "Salary har mahine ki {ord} ko aati hai.", "ye mera {ord} reminder hai.", "meeting {ord} ko hai, kal nahi.",
],
"pn": [
 "page {pn} kholo aur padhna shuru karo.", "slide {pn} pe numbers galat hain.", "ticket {pn} ko pehle fix karo.", "room {room} mein meeting hai.", "step {pn} pe error aa raha hai.", "Chapter {pn} kal tak padh lena.",
],
"unit": [
 "office yahan se {unit_km} door hai.", "laptop mein {unit_gb} ki storage hai.", "internet {unit_mbps} ki speed de raha hai.", "file {unit_gb} ki hai, upload nahi ho rahi.",
],
"ver": [
 "abhi hum version {ver} pe hain.", "ye bug version {ver} mein fix hua tha.", "{qtr} ka target miss ho gaya.", "{qtr} ki planning {day} ko hai.", "{ver_sw} pe build fail ho raha hai.",
],
"id": [
 "mera employee ID {id} hai.", "OTP {id} hai, kisi ko mat batana.", "order number {id} hai, check karo.", "mujhe {id} par call karna.",
],
"multi": [
 "kal {hrh} baje {dm} ka review hai, {name} present karega.", "{year} mein start kiya tha, aaj {pct} growth hai.", "Budget {inr} hai aur deadline {dm} hai.", "{hdays} din mein {inr} ka kaam karna hai.",
 "{dm} ko {time} pe call hai, {cobj_h} log join karenge.", "Version {ver} {my} mein release hua tha.",
],
}
def s_cobj_h():
    n = R.choice([2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 50]); hw = {2: "do", 3: "teen", 4: "char", 5: "paanch", 6: "chhah", 8: "aath", 10: "das"}
    return str(n), (hw[n] if n in hw and R.random() < .5 else w(n))
SLOTS["cobj_h"] = s_cobj_h
SLOTS["rng_year"] = lambda: (lambda a: (f"{a}-{a+1}", f"{yearw(a)} to {yearw(a+1)}"))(R.randint(2015, 2024))
SLOTS["unit_gb"] = lambda: (lambda n, u: (f"{n} {u}", f"{w(n)} {' '.join(u)}"))(R.choice([4, 8, 16, 32, 64, 128, 256, 500]), R.choice(["GB", "GB", "MB", "TB"]))
SLOTS["unit_km"] = lambda: (lambda n: (f"{n} km", f"{w(n)} kilometres"))(R.choice([2, 3, 5, 8, 10, 12, 15, 20, 25, 40, 120]))
SLOTS["unit_ms"] = lambda: (lambda n: (f"{n} ms", f"{w(n)} milliseconds"))(R.choice([20, 50, 80, 100, 150, 200, 250, 300, 500]))
SLOTS["unit_mbps"] = lambda: (lambda n: (f"{n} Mbps", f"{w(n)} M B P S"))(R.choice([20, 50, 100, 200, 500]))
SLOTS["unit_kg"] = lambda: (lambda n: (f"{n} kg", f"{w(n)} kilos"))(R.choice([2, 3, 5, 8, 10, 12, 20, 25, 50]))
SLOTS["dur_digit"] = s_dur_digit
SLOTS["cobj2"] = s_cobj
SLOTS["time2"] = s_time
SLOTS["dm2"] = s_dm
SLOTS["year2"] = s_year
SLOTS["q"] = lambda: (lambda q: (str(q), w(q)))(R.randint(1, 4))
SLOTS["between"] = s_between
def s_rngn():
    while True:
        t,sp=s_rng()
        if not re.match(r"(19|20)\d\d",t) and not re.match(r"(9|10|11) to ",t): return t,sp
def s_rngh():
    a=R.choice([9,10,11,8]); b=R.choice([5,6,7,4]); return f"{a} to {b}", f"{w(a)} to {w(b)}"
SLOTS["rngn"]=s_rngn; SLOTS["rngh"]=s_rngh
SLOTS["pct"] = s_pct

PLAIN = {
 "name": lambda: NAMES, "day": lambda: DAYS, "city": lambda: CITIES, "topic": lambda: TOPIC, "Topic": lambda: [t[0].upper() + t[1:] for t in TOPIC] , "thing": lambda: THING, "team": lambda: TEAM,
 "place": lambda: PLACE, "food": lambda: FOOD,
}
TK = re.compile(r"\{(\w+)\}")
def fill(tpl):
    t_parts, s_parts = [], []
    # one draw per slot occurrence
    out_t, out_s = [], []
    pos = 0; plain_cache = {}
    for m in TK.finditer(tpl):
        out_t.append(tpl[pos:m.start()]); out_s.append(tpl[pos:m.start()]); pos = m.end()
        k = m.group(1)
        if k in SLOTS:
            if k == "lakh_n": pass
            t, s = SLOTS[k]()
            if s is None: s = w(int(t.split()[0])) + " lakh"
            out_t.append(t); out_s.append(s)
        else:
            if k in ("name", "day", "city", "place") and k in plain_cache: v = plain_cache[k]
            else: v = R.choice(PLAIN[k]()); plain_cache[k] = v
            out_t.append(v); out_s.append(v)
    out_t.append(tpl[pos:]); out_s.append(tpl[pos:])
    return "".join(out_t), "".join(out_s)

def spoken_fix(s):
    # speak side: letters/acronyms spoken; keep punctuation light
    s = re.sub(r"\bQ(\d)", lambda m: "Q " + ONES[int(m.group(1))], s)
    s = s.replace("GST", "G S T").replace("OTP", "O T P").replace("API", "A P I").replace("PR", "P R").replace("AWS", "A W S").replace("QA", "Q A").replace("HR", "H R")
    s = s.replace("CGPA", "C G P A").replace("ARR", "A R R").replace("EMI", "E M I").replace("PO ", "P O ").replace("ID", "I D").replace("CPU", "C P U").replace("UK", "U K")
    s = s.replace("₹", "")
    return re.sub(r"\s+", " ", s)

def capital(s): return s[0].upper() + s[1:] if s and s[0].islower() and not s.startswith(("kal", "ye ")) else s

WEIGHT_EN = {"hour": 9, "time": 8, "time24": 1, "year": 8, "decade": 0.8, "my": 3, "dm": 5, "dmy": 1.5, "md": 1, "ord": 4, "dayn": 1, "cnt": 6, "cnt_digit": 3, "cobj": 5, "net": 1.5, "pn": 8, "room": 1.5,
             "inr": 9, "usd": 2, "pct": 8, "ver": 2, "ver_sw": 2, "qtr": 4, "unit": 4, "rng": 3, "id": 2.5, "pin": 0.7, "dec": 2, "k": 1, "bignum": 2, "multi": 9}
WEIGHT_HI = {"hour": 5, "time": 3, "year": 2, "dm": 3, "cnt": 4, "inr": 4, "pct": 3, "ord": 1, "pn": 2, "unit": 1, "ver": 1.5, "id": 0.8, "multi": 2.5}

def classify(tpl_type): return tpl_type

def main():
    seen = set(); rows = []
    types = collections.Counter()
    nHI = int(TARGET * 0.17)
    attempts = 0
    while len(rows) < TARGET and attempts < TARGET * 30:
        attempts += 1
        hi = len(rows) < 0 or R.random() < 0.17
        D = HI if hi else EN; W = WEIGHT_HI if hi else WEIGHT_EN
        ty = R.choices(list(D), weights=[W[k] for k in D])[0]
        tpl = R.choice(D[ty])
        t, s = fill(tpl)
        if not hi and ty not in ("multi",) and R.random() < .6:
            op = R.choice(OPEN); cl = R.choice(CLOSE)
            if "{name}" in op: nm = R.choice(NAMES); op = op.replace("{name}", nm)
            t = op + (t if not op or op.endswith(", ") and False else t); s = op + s
            t += cl; s += cl
            # lowercase first letter after opener
            if op and t[len(op)].isupper() and t[len(op):len(op) + 2] not in ("I ", "I'") and not re.match(r"[A-Z]{2}|Q\d", t[len(op):]) and not any(t[len(op):].startswith(x) for x in NAMES + CITIES + DAYS + ["Python", "Node", "Java", "iOS", "Android", "Windows", "Postgres", "Angular", "React", "Ubuntu", "AWS"]):
                t = t[:len(op)] + t[len(op)].lower() + t[len(op) + 1:]; s = s[:len(op)] + s[len(op)].lower() + s[len(op) + 1:]
        elif hi and R.random() < .25:
            op = R.choice(["Yaar, ", "Suno, ", "Bhai, ", "Arre, ", "Dekho, ", "Please, "]); cl = R.choice(["", " Thanks.", " Dhyan rakhna.", " ok?", " Reply kar dena.", " Let me know."])
            t = op + t + cl; s = op + s + cl
        if not hi: t = capital(t); s = capital(s)
        s = spoken_fix(s)
        if len(t.split()) > 24 or len(t.split()) < 4: continue
        key = re.sub(r"[^a-z0-9₹$ ]", "", t.lower()).strip()
        if key in seen: continue
        seen.add(key)
        rows.append(dict(text=t, speak=s, mix="hinglish" if hi else "en", terms=[], ntype=ty))
        types[(hi, ty)] += 1
    return rows

if __name__ == "__main__":
    rows = main()
    R.shuffle(rows)
    out = sys.argv[3] if len(sys.argv) > 3 else "/tmp/num_raw.jsonl"
    with open(out, "w") as f:
        for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(len(rows), collections.Counter(r["mix"] for r in rows))
