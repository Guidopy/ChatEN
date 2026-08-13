-- ChatEN: salida es->en + entrada en->es en todos los canales
-- Tab (con el chat abierto) alterna la traduccion saliente
-- Log de errores: se persiste en SavedVariables (WTF/Account/SavedVariables/ChatEN.lua)
--   /chaten log   -> muestra el log
--   /chaten clear -> limpia el log
local enabled = ChatEN_Enabled ~= false
local origMode = ChatEN_ShowOriginal == true
local debug = false
local cfg
local function ParseHexClr(s)
    if type(s) ~= "string" then return nil end
    local r, g, b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
    if not (r and g and b) then return nil end
    return { r / 255, g / 255, b / 255 }
end
local function LoadColor(hex, tbl, def)
    local c = ParseHexClr(hex)
    if c then return c end
    if type(tbl) == "table" and type(tbl[1]) == "number" and type(tbl[2]) == "number" and type(tbl[3]) == "number" then
        return { tbl[1], tbl[2], tbl[3] }
    end
    return def
end
-- savada vieja corrupta (string/nil) no debe tumbar el panel: todo con fallback
local origC = LoadColor(ChatEN_ColorOriginal, ChatEN_OrigColor, { 0.6, 0.6, 0.65 })
local transC = LoadColor(ChatEN_ColorTranslated, ChatEN_TransColor, { 0.45, 1, 0.6 })
local PRESETS = {
    { 0.6, 0.6, 0.65 }, { 1, 1, 1 }, { 0.3, 1, 0.5 }, { 0.4, 0.85, 1 },
    { 1, 1, 0.4 }, { 1, 0.65, 0.3 }, { 1, 0.4, 0.4 }, { 1, 0.4, 0.9 },
    { 0.3, 0.9, 1 }, { 0.7, 1, 0.3 }, { 0.6, 0.4, 1 }, { 1, 0.85, 0.5 },
}
local function Hex(c)
    return string.format("%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end
local mmSetIcon

ChatEN_Log = ChatEN_Log or {}

local function Now()
    if pcall(date) then return date("%H:%M:%S") end
    return "?"
end

local function Log(msg)
    table.insert(ChatEN_Log, { Now(), tostring(msg) })
    while #ChatEN_Log > 50 do table.remove(ChatEN_Log, 1) end
end

-- Diagnostico: capturar todos los errores Lua del cliente en el log
-- (silencia el cartel "too many errors" y con /chaten log vemos el addon culpable)
if geterrorhandler and seterrorhandler then
    seterrorhandler(function(msg)
        Log("LUA: " .. tostring(msg))
    end)
end

local okInit, initErr = xpcall(function()

    -- Data1..DataN vienen como strings planos "clave<TAB>traduccion" por linea
    -- (las tablas del toc ya son hashmaps {clave = traduccion}; lookup directo)
    local EN_T = {}
    local ES_T = {}
    local nData = 0
    while _G["ChatENEnDictData" .. (nData + 1)] do nData = nData + 1 end
    for i = 1, nData do
        EN_T[i] = _G["ChatENEnDictData" .. i]
        ES_T[i] = _G["ChatENDictData" .. i]
        _G["ChatENDictData" .. i] = nil
        _G["ChatENEnDictData" .. i] = nil
    end
    -- frases propias del usuario (ChatEN_Custom): prioridad sobre el diccionario
    ChatEN_Custom = ChatEN_Custom or {}
    local nCustom = 0
    for _ in pairs(ChatEN_Custom) do nCustom = nCustom + 1 end
    print("|cff00ff00[ChatEN]|r frases propias restauradas: " .. nCustom)
    table.insert(EN_T, 1, ChatEN_Custom)
    table.insert(ES_T, 1, ChatEN_Custom)
    -- Desambiguacion por contexto: la palabra siguiente decide la traduccion.
    -- Formato: [palabra] = { "direccion" ("es"=salida, "en"=entrada), { siguiente = traduccion } }
    local CTX = {
        ["para"] = { "es", { preciso = "stop", necesito = "stop", quiero = "stop", paren = "stop", basta = "stop", exijo = "stop", escucha = "stop", mira = "stop" } },
        ["does"] = { "en", { anyone = "alguien", anybody = "alguien", somebody = "alguien", someone = "alguien" } },
    }
    local CTX_T = { es = {}, en = {} }
    for w, c in pairs(CTX) do
        for nxt, tr in pairs(c[2]) do
            CTX_T[c[1]][w .. " " .. nxt] = tr
        end
    end
    table.insert(ES_T, 2, CTX_T.es)
    table.insert(EN_T, 2, CTX_T.en)

    -- Reemplaza claves del indice en el mensaje. Para cada palabra de inicio
    -- prueba las claves candidatas de la mas larga a la mas corta (longest-first),
    -- con lookup O(1) por clave; los limites de palabra los da el propio gmatch.
    -- Fallback morfologico: si la palabra suelta no esta en el diccionario,
    -- prueba su lema (plurales -s/-es, gerundios -ing, pasados -ed, -ly) y le
    -- aplica el sufijo espanol aproximado. ponytail: aproximado (regulares),
    -- los irregulares que importan (died, went...) estan curados en el dict.
    local function StemTranslate(w, tables)
        if #w <= 4 then return nil end        local function get(k)
            for t = 1, #tables do
                local v = tables[t][k]
                if v then return v end
            end
        end
        local tr, kind
        if w:sub(-3) == "ing" then
            local tw = w:sub(1, -4)
            tr = get(tw)
            if not tr and tw:sub(-1) == tw:sub(-2, -2) then tr = get(tw:sub(1, -2)) end
            kind = "ger"
        elseif w:sub(-3) == "ies" then
            tr = get(w:sub(1, -3) .. "y"); kind = "plu"
        elseif w:sub(-3) == "ied" then
            tr = get(w:sub(1, -3) .. "y"); kind = "past"
        elseif w:sub(-2) == "es" then
            tr = get(w:sub(1, -2)); kind = "plu"
        elseif w:sub(-2) == "ed" then
            tr = get(w:sub(1, -2)); kind = "past"
        elseif w:sub(-2) == "ly" then
            tr = get(w:sub(1, -2)); kind = "ly"
        elseif w:sub(-1) == "s" then
            local tw = w:sub(1, -2)
            tr = get(tw)
            if not tr and tw:sub(-1) == "e" then tr = get(tw:sub(1, -2) .. "y") end
            kind = "plu"
        end
        if not tr then return nil end
        local last = tr:sub(-1)
        if kind == "plu" then
            if tr:find("[aeiouáéíóú]$") then tr = tr .. "s"
            elseif last ~= "s" then tr = tr .. "es" end
        elseif kind == "ger" then
            if tr:sub(-2) == "ar" then tr = tr:sub(1, -3) .. "ando"
            elseif tr:sub(-2) == "er" then tr = tr:sub(1, -3) .. "iendo"
            elseif tr:sub(-2) == "ir" then tr = tr:sub(1, -3) .. "iendo" end
        elseif kind == "past" then
            if tr:sub(-2) == "ar" then tr = tr:sub(1, -3) .. "ado"
            elseif tr:sub(-2) == "er" then tr = tr:sub(1, -3) .. "ido"
            elseif tr:sub(-2) == "ir" then tr = tr:sub(1, -3) .. "ido" end
        elseif kind == "ly" then
            tr = tr .. "mente"
        end
        return tr
    end

    -- lookup directo sin filtro de longitud (para las reglas de reorden)
    local function getTr(w, tables)
        for t = 1, #tables do
            local v = tables[t][w]
            if v then return v end
        end
        local flat = w
        local TILDES = { ["á"]="a",["é"]="e",["í"]="i",["ó"]="o",["ú"]="u",["ü"]="u",["Á"]="A",["É"]="E",["Í"]="I",["Ó"]="O",["Ú"]="U",["Ü"]="U",["ñ"]="n",["Ñ"]="N" }
        local hasT = false
        for k, v in pairs(TILDES) do
            if w:find(k, 1, true) then hasT = true end
            flat = flat:gsub(k, v)
        end
        if hasT then
            for t = 1, #tables do
                local v = tables[t][flat]
                if v then return v end
            end
        end
    end

    -- Links de items/spells/jugadores: se protegen antes de traducir y se
    -- restauran intactos, para que el cliente siga renderizandolos clickeables.
    -- Placeholder: emoji + numero (el matcher de palabras no lo toca).
    local B = "\226\154\161"
    local function ProtectLinks(text)
        local links = {}
        for _, pat in ipairs({ "|c%x+%b||h%[[^]]*%]|h|r", "%b||h%[[^]]*%]|h|r" }) do
            text = text:gsub(pat, function(link)
                links[#links + 1] = link
                return B .. #links .. B
            end)
        end
        return text, links
    end
    local function RestoreLinks(text, links)
        for i = 1, #links do
            text = text:gsub(B .. i .. B, links[i], 1)
        end
        return text
    end

    -- Clases custom del server (Wow Ascension, Vol'jin): nunca se traducen.
    local CLASSES = {
        "barbarian", "bard", "blood mage", "chronomancer", "cultist",
        "demon hunter", "dragon knight", "engineer", "necromancer", "primalist",
        "pyromancer", "reaper", "shadow hunter", "son of arugal", "soulcrafter",
        "starcaller", "sunwalker", "tinkerer", "venomancer", "witch doctor",
        "witch hunter",
        "warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage",
        "warlock", "druid",
    }
    local W = "%a%d'Ã¡Ã©Ã­Ã³ÃºÃ¼Ã±ÃÃÃÃÃÃÃ"
    local function ProtectClasses(text, links)
        local lower = string.lower(text)
        local words = {}
        for startPos, word in string.gmatch(lower, "()([" .. W .. "]+)") do
            words[#words + 1] = { startPos, word }
        end
        local ranges = {}
        local n = #words
        local i = 1
        while i <= n do
            local ph
            for len = 3, 1, -1 do
                if i + len - 1 <= n then
                    local cand = words[i][2]
                    for k = i + 1, i + len - 1 do cand = cand .. " " .. words[k][2] end
                    for _, c in ipairs(CLASSES) do
                        if cand == c then ph = len break end
                    end
                    if ph then break end
                end
            end
            if ph then
                ranges[#ranges + 1] = { words[i][1], words[i + ph - 1][1] + #words[i + ph - 1][2] - 1 }
                i = i + ph
            else
                i = i + 1
            end
        end
        local pieces, last = {}, 1
        for _, r in ipairs(ranges) do
            if r[1] > last then pieces[#pieces + 1] = string.sub(text, last, r[1] - 1) end
            links[#links + 1] = string.sub(text, r[1], r[2])
            pieces[#pieces + 1] = B .. #links .. B
            last = r[2] + 1
        end
        pieces[#pieces + 1] = string.sub(text, last)
        return table.concat(pieces)
    end

    -- Adjetivos que en espanol van DESPUES del sustantivo: reorden generativo.
    -- EN->ES: "big ogre" → "ogro grande". ES->EN: "ogro grande" → "big ogre".
    -- Traduccion propia (no el dict: "red" ahi es "network"). La concordancia
    -- de genero la resuelve el corpus; esta regla es fallback.
    local ADJPOST_EN = { big = "grande", red = "rojo", blue = "azul", green = "verde", black = "negro", white = "blanco", new = "nuevo", old = "viejo", small = "pequeño", little = "pequeño", huge = "enorme", giant = "gigante", epic = "épico", rare = "raro", legendary = "legendario", fast = "rápido", slow = "lento", strong = "fuerte", weak = "débil", dead = "muerto", full = "lleno", empty = "vacío", easy = "fácil", hard = "difícil", dark = "oscuro", bright = "brillante", ancient = "antiguo", strange = "extraño", powerful = "poderoso", dangerous = "peligroso", friendly = "amistoso", hostile = "hostil", amazing = "increíble", awesome = "genial", terrible = "terrible", wonderful = "maravilloso", beautiful = "hermoso", ugly = "feo", rich = "rico", poor = "pobre", young = "joven", secret = "secreto", hidden = "oculto", great = "grande", next = "siguiente", last = "último", first = "primero" }
    local ADJPOST_ES = { grande = true, grandes = true, rojo = true, rojos = true, roja = true, rojas = true, azul = true, azules = true, verde = true, verdes = true, negro = true, negros = true, negra = true, negras = true, blanco = true, blancos = true, blanca = true, blancas = true, nuevo = true, nuevos = true, nueva = true, nuevas = true, viejo = true, viejos = true, vieja = true, viejas = true, ["pequeño"] = true, ["pequeños"] = true, ["pequeña"] = true, ["pequeñas"] = true, enorme = true, enormes = true, ["épico"] = true, ["épicos"] = true, ["épica"] = true, ["épicas"] = true, raro = true, raros = true, rara = true, raras = true, legendario = true, legendarios = true, legendaria = true, legendarias = true, ["rápido"] = true, ["rápidos"] = true, ["rápida"] = true, ["rápidas"] = true, lento = true, lentos = true, lenta = true, lentas = true, fuerte = true, fuertes = true, ["débil"] = true, ["débiles"] = true, muerto = true, muertos = true, muerta = true, muertas = true, lleno = true, llenos = true, llena = true, llenas = true, ["vacío"] = true, ["vacíos"] = true, ["vacía"] = true, ["vacías"] = true, ["fácil"] = true, ["fáciles"] = true, ["difícil"] = true, ["difíciles"] = true, genial = true, geniales = true, gigante = true, gigantes = true, poderoso = true, poderosos = true, poderosa = true, poderosas = true, peligroso = true, peligrosos = true, peligrosa = true, peligrosas = true, bonito = true, bonitos = true, bonita = true, bonitas = true, horrible = true, horribles = true, antiguo = true, antiguos = true, antigua = true, antiguas = true, ["extraño"] = true, ["extraños"] = true, ["extraña"] = true, ["extrañas"] = true, oscuro = true, oscuros = true, oscura = true, oscuras = true, secreto = true, secretos = true, secreta = true, secretas = true, oculto = true, ocultos = true, oculta = true, ocultas = true }
    -- verbos espanoles frecuentes: si preceden a un adjetivo, no son sustantivo
    local NOVERB_ES = { soy = true, eras = true, eres = true, es = true, somos = true, son = true, era = true, eran = true, fui = true, fue = true, estoy = true, ["estás"] = true, ["está"] = true, estamos = true, ["están"] = true, estaba = true, estaban = true, tengo = true, tienes = true, tiene = true, tenemos = true, tienen = true, ["tenía"] = true, hago = true, haces = true, hace = true, hacemos = true, hacen = true, hice = true, hizo = true, voy = true, vas = true, va = true, vamos = true, van = true, quiero = true, quieres = true, quiere = true, quieren = true, ["quería"] = true, necesito = true, necesitas = true, necesita = true, necesitan = true, busco = true, buscas = true, busca = true, buscan = true, ["sé"] = true, cojo = true, toma = true, tomo = true, usa = true, uso = true, hay = true, ves = true, veo = true, vi = true, viste = true, doy = true, das = true, da = true, dan = true }

    -- ── Verbos frecuentes de chat: [infinitivo] = { presente, pasado, gerundio, futuro }
    local VERBS = {
        ir = { "go", "went", "going", "will go" }, venir = { "come", "came", "coming", "will come" },
        hablar = { "talk", "talked", "talking", "will talk" }, decir = { "say", "said", "saying", "will say" },
        ver = { "see", "saw", "seeing", "will see" }, mirar = { "look", "looked", "looking", "will look" },
        buscar = { "look for", "looked for", "looking for", "will look for" }, vender = { "sell", "sold", "selling", "will sell" },
        comprar = { "buy", "bought", "buying", "will buy" }, cambiar = { "trade", "traded", "trading", "will trade" },
        regalar = { "give away", "gave away", "giving away", "will give away" }, necesitar = { "need", "needed", "needing", "will need" },
        querer = { "want", "wanted", "wanting", "will want" }, tener = { "have", "had", "having", "will have" },
        hacer = { "do", "did", "doing", "will do" }, poder = { "be able to", "could", "being able to", "will be able to" },
        dar = { "give", "gave", "giving", "will give" }, tomar = { "take", "took", "taking", "will take" },
        correr = { "run", "ran", "running", "will run" }, jugar = { "play", "played", "playing", "will play" },
        matar = { "kill", "killed", "killing", "will kill" }, curar = { "heal", "healed", "healing", "will heal" },
        ayudar = { "help", "helped", "helping", "will help" }, usar = { "use", "used", "using", "will use" },
        entrar = { "go in", "went in", "going in", "will go in" }, salir = { "leave", "left", "leaving", "will leave" },
        empezar = { "start", "started", "starting", "will start" }, terminar = { "finish", "finished", "finishing", "will finish" },
        esperar = { "wait", "waited", "waiting", "will wait" }, pagar = { "pay", "paid", "paying", "will pay" },
        cobrar = { "charge", "charged", "charging", "will charge" }, volver = { "return", "returned", "returning", "will return" },
        morir = { "die", "died", "dying", "will die" }, revivir = { "revive", "revived", "reviving", "will revive" },
        luchar = { "fight", "fought", "fighting", "will fight" }, atacar = { "attack", "attacked", "attacking", "will attack" },
        farmear = { "farm", "farmed", "farming", "will farm" }, invitar = { "invite", "invited", "inviting", "will invite" },
        unirse = { "join", "joined", "joining", "will join" }, dropear = { "drop", "dropped", "dropping", "will drop" },
    }
    -- Irregulares comunes: forma exacta -> ingles (evita derivaciones falsas
    -- tipo "va" -> strip de "a" -> ver). ponytail: las irregularidades reales
    -- estan curadas aqui; las de estem-vocal quedan en el dict de corpus.
    local CONJ_EXACT = {
        va = "goes", vas = "go", van = "go", voy = "go", fui = "went", fuiste = "went",
        fue = "went", fuimos = "went", fueron = "went", era = "was", eras = "was",
        eran = "were", estaba = "was", estabas = "was", estaban = "were",
        estoy = "i am", ["está"] = "is", ["están"] = "are", ["tenía"] = "had",
        quiero = "want", quieres = "want", quiere = "wants", queremos = "want", quieren = "want",
        tengo = "have", tienes = "have", tiene = "has", tenemos = "have", tienen = "have",
        hago = "do", haces = "do", hace = "does", hacemos = "do", hacen = "do",
        puedo = "can", puedes = "can", puede = "can", podemos = "can", pueden = "can",
        ["sé"] = "i know", vi = "saw", dijo = "said", dice = "says", dije = "said", di = "gave",
    }
    -- Conjuga una palabra espanola a su forma inglesa (o nil si no es verbo).
    -- Solo dispara si deriva una raiz real (>= 3 letras) que exista en VERBS.
    local function ConjugateEs(w)
        local ex = CONJ_EXACT[w]
        if ex then return ex end
        if VERBS[w] then return VERBS[w][1] end
        local function tryStem(stem, idx)
            if #stem < 3 then return nil end
            for _, c in ipairs({ "ar", "er", "ir" }) do
                local v = VERBS[stem .. c]
                if v then return v[idx] end
            end
        end
        for _, sf in ipairs({ "ando", "iendo" }) do
            if w:sub(-#sf) == sf then return tryStem(w:sub(1, -#sf - 1), 3) end
        end
        for _, sf in ipairs({ "aré", "arás", "ará", "aremos", "aréis", "arán", "eré", "erás", "erá", "eremos", "eréis", "erán", "iré", "irás", "irá", "iremos", "iréis", "irán" }) do
            if w:sub(-#sf) == sf then local v = tryStem(w:sub(1, -#sf - 1), 1); return v and ("will " .. v) end
        end
        for _, sf in ipairs({ "ado", "ados", "ada", "adas" }) do
            if w:sub(-#sf) == sf then return tryStem(w:sub(1, -#sf - 1), 2) end
        end
        for _, sf in ipairs({ "aba", "abas", "ábamos", "abais", "aban", "ía", "ías", "íamos", "íais", "ían" }) do
            if w:sub(-#sf) == sf then return tryStem(w:sub(1, -#sf - 1), 2) end
        end
        for _, sf in ipairs({ "é", "aste", "ó", "amos", "asteis", "aron", "í", "iste", "ió", "imos", "isteis", "ieron" }) do
            if w:sub(-#sf) == sf then return tryStem(w:sub(1, -#sf - 1), 2) end
        end
        for _, sf in ipairs({ "as", "a", "amos", "áis", "an", "es", "e", "emos", "éis", "en", "imos", "ís", "o" }) do
            if w:sub(-#sf) == sf then return tryStem(w:sub(1, -#sf - 1), 1) end
        end
        return nil
    end

    -- Patrones de chat: estructuras completas -> equivalente fluido.
    -- Se aplican DESPUES de frases del dict y ANTES de palabras sueltas.
    -- ponytail: lista curada de trade/group speak; se amplia si aparece un caso nuevo.
    local PAT_ES = {
        { "^busco%s+(.+)", "looking for " }, { "^vendo%s+(.+)", "selling " },
        { "^compro%s+(.+)", "buying " }, { "^cambio%s+(.+)", "trading " },
        { "^regalo%s+(.+)", "giving away " }, { "^necesito%s+(.+)", "need " },
        { "^quiero%s+(.+)", "want " }, { "^voy a%s+(.+)", "going to " },
        { "^vamos a%s+(.+)", "let's " }, { "^tengo que%s+(.+)", "have to " },
        { "^hay que%s+(.+)", "have to " }, { "^hay%s+(.+)", "there is " },
        { "^dame%s+(.+)", "give me " }, { "^estoy%s+(.+)", "i am " },
        { "^puedes%s+(.+)", "you can " }, { "^puedo%s+(.+)", "i can " },
        { "^por favor%s+(.+)", "please " },
    }
    local PAT_EN = {
        { "^looking for%s+(.+)", "busco " }, { "^selling%s+(.+)", "vendo " },
        { "^buying%s+(.+)", "compro " }, { "^need%s+(.+)", "necesito " },
        { "^want%s+(.+)", "quiero " }, { "^going to%s+(.+)", "voy a " },
        { "^let's%s+(.+)", "vamos " }, { "^there is%s+(.+)", "hay " },
        { "^give me%s+(.+)", "dame " }, { "^i am%s+(.+)", "estoy " },
        { "^you can%s+(.+)", "puedes " }, { "^lf%s+(.+)", "busco " },
        { "^lfg%s+(.+)", "busco " }, { "^lfr%s+(.+)", "busco " },
        { "^wts%s+(.+)", "vendo " }, { "^wtb%s+(.+)", "compro " },
        { "^please%s+(.+)", "por favor " },
    }

    local function Translate(msg, tables, dir, depth)
        local links
        msg, links = ProtectLinks(msg)
        msg = ProtectClasses(msg, links)
        local lower = string.lower(msg)
        local words = {}
        for startPos, word in string.gmatch(lower, "()([%a%d'Ã¡Ã©Ã­Ã³ÃºÃ¼Ã±ÃÃÃÃÃÃÃ]+)") do
            words[#words + 1] = { startPos, word }
        end
        depth = depth or 1
        local parts, last, has = {}, 1, false
        local n = #words
        for i = 1, n do
            local startPos = words[i][1]
            if startPos >= last then
                local found
                -- 1) frases completas / palabras variantes: longest-match
                for j = n, i + 1, -1 do
                    local cur = words[i][2]
                    for k = i + 1, j do cur = cur .. " " .. words[k][2] end
                    local tr
                    for t = 1, #tables do
                        tr = tables[t][cur]
                        if tr then break end
                    end
                    -- Reorden generativo de adjetivos (cuando el bigrama no
                    -- esta en el corpus): ES->EN "ogro grande" -> "big ogre";
                    -- EN->ES "big ogre" -> "ogro grande"
                    if not tr and j == i + 1 then
                        if ADJPOST_ES[words[j][2]] and not NOVERB_ES[words[i][2]] then
                            local ntr = getTr(words[i][2], tables)
                            if ntr then
                                tr = getTr(words[j][2], tables) .. " " .. ntr
                            end
                        elseif ADJPOST_EN[words[i][2]] then
                            local ntr = getTr(words[j][2], tables)
                            if ntr and ntr ~= "" then
                                local atr = ADJPOST_EN[words[i][2]]
                                if ntr:sub(-1) == "s" and atr:sub(-1) ~= "s" then atr = atr .. "s" end
                                tr = ntr .. " " .. atr
                            end
                        end
                    end
                    if tr then
                        if startPos > last then parts[#parts + 1] = string.sub(msg, last, startPos - 1) end
                        parts[#parts + 1] = tr
                        last = words[j][1] + #words[j][2]
                        has = true
                        found = true
                        break
                    end
                end
                -- 2) patrones de chat: "busco x" -> "looking for x"
                if not found and depth <= 2 then
                    local pats = dir == "es" and PAT_ES or PAT_EN
                    local full = string.sub(lower, startPos)
                    for p = 1, #pats do
                        local cap = full:match(pats[p][1])
                        if cap then
                            local tr = Translate(cap, tables, dir, depth + 1)
                            if startPos > last then parts[#parts + 1] = string.sub(msg, last, startPos - 1) end
                            parts[#parts + 1] = pats[p][2] .. tr
                            last = startPos + #full - #cap
                            has = true
                            found = true
                            break
                        end
                    end
                end
                -- 3) verbos conjugados (antes que la palabra suelta del dict)
                if not found then
                    local tr = ConjugateEs(words[i][2])
                    if tr then
                        if startPos > last then parts[#parts + 1] = string.sub(msg, last, startPos - 1) end
                        parts[#parts + 1] = tr
                        last = startPos + #words[i][2]
                        has = true
                        found = true
                    end
                end
                -- 4) palabra suelta del diccionario
                if not found then
                    local tr
                    for t = 1, #tables do
                        tr = tables[t][words[i][2]]
                        if tr then break end
                    end
                    if tr then
                        if startPos > last then parts[#parts + 1] = string.sub(msg, last, startPos - 1) end
                        parts[#parts + 1] = tr
                        last = startPos + #words[i][2]
                        has = true
                        found = true
                    end
                end
                -- 5) fallback morfologico final
                if not found then
                    local tr = StemTranslate(words[i][2], tables)
                    if tr then
                        if startPos > last then parts[#parts + 1] = string.sub(msg, last, startPos - 1) end
                        parts[#parts + 1] = tr
                        last = startPos + #words[i][2]
                        has = true
                    end
                end
            end
        end
        if not has then return RestoreLinks(msg, links) end
        parts[#parts + 1] = string.sub(msg, last)
        return RestoreLinks(table.concat(parts), links)
    end

    -- ── Salida: traducir lo que escribo (es->en) ────────────────────────────
    local original = SendChatMessage
    local translating = false

    SendChatMessage = function(text, chatType, language, target)
        if enabled and not translating and text and text ~= "" then
            local ok, en = pcall(Translate, text, ES_T, "es")
            if not ok then
                Log("SendChat Translate: " .. tostring(en))
            elseif en ~= text then
                translating = true
                local ok2 = pcall(original, en, chatType, language, target)
                translating = false
                if not ok2 then Log("SendChat original: " .. tostring(en)) end
                -- sin eco propio: el cliente muestra el mensaje enviado con el
                -- nombre del PJ, y el traducido se ve en el chat del destinatario
                return
            end
        end
        original(text, chatType, language, target)
    end

    -- ── Entrada: traducir todo lo que llega a espanol (en->es) ──────────────
    -- Canales: todos activos por defecto. Click derecho en el icono del
    -- minimapa para activar/desactivar por canal (guardado en ChatEN_Channels).
    local ENTRA = {
        "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
        "CHAT_MSG_PARTY_GUIDE", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
        "CHAT_MSG_RAID_BOSS_WHISPER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_WHISPER",
        "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_CHANNEL", "CHAT_MSG_INSTANCE_CHAT",
        "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
        "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE",
        "CHAT_MSG_MONSTER_WHISPER", "CHAT_MSG_MONSTER_PARTY", "CHAT_MSG_MONSTER_BOSS_EMOTE",
        "CHAT_MSG_MONSTER_BOSS_WHISPER", "CHAT_MSG_BG_HORDE", "CHAT_MSG_BG_ALLIANCE",
        "CHAT_MSG_BG_NEUTRAL",}
    
    if type(ChatEN_Channels) ~= "table" then ChatEN_Channels = {} end
    if type(ChatEN_ChannelNames) ~= "table" then ChatEN_ChannelNames = {} end
    local anyChannel = false
    for _, e in ipairs(ENTRA) do
        if ChatEN_Channels[e] ~= nil then anyChannel = true end
    end
    -- si la tabla guardada no tiene ningun canal (versiones viejas / corrupcion):
    -- activar todos. Si el usuario configuro alguno, respetar su config.
    if not anyChannel then
        for _, e in ipairs(ENTRA) do ChatEN_Channels[e] = true end
    end

    -- IMPORTANTE: este cliente de Ascension llama a los filtros con la firma
    -- filterFunc(chatFrame, event, msg, author, ...) (un arg mas que el stock).
    -- BabelChat usaba (self, event, text, author, ...) — por eso le andaba.

    -- DIAG temporal: registra los primeros mensajes/eventos que pasan por cada
    -- etapa, para ubicar de donde sale el texto que el filtro no ve.
    local diagN = 0
    local function DiagLine(s)
        if diagN < 300 then
            diagN = diagN + 1
            table.insert(ChatEN_Log, { Now(), "DIAG " .. tostring(s) })
        end
    end

    local function ChatFilter(self, event, msg, author, ...)
        DiagLine("F " .. tostring(event) .. "|" .. tostring(msg) .. "|author=" .. tostring(author) .. "|" .. tostring((select(2, ...))))
        if debug then
            if type(msg) == "string" then
                Log("[CHAT] " .. tostring(event) .. " | " .. tostring(select(2, ...)) .. " | " .. string.sub(msg, 1, 40))
            elseif type(msg) == "table" then
                local parts = {}
                for k, v in pairs(msg) do
                    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
                    if #parts >= 8 then break end
                end
                Log("[CHAT] " .. tostring(event) .. " | TABLE: " .. table.concat(parts, ", "))
            else
                Log("[CHAT] " .. tostring(event) .. " | " .. type(msg))
            end
        end
        -- un filtro JAMAS puede tirar error: el cliente aborta el pipeline de
        -- chat y los mensajes dejan de mostrarse (canales "vacios").
        if type(event) ~= "string" or type(msg) ~= "string" or msg == "" then return end
        -- tokens del servidor (LC1:CONF:...): no son chat real, ocultar (true = ocultar en 3.3.5)
        if string.match(msg, "^LC[1-5]:") then return true end
        -- canales personalizados (Ascension): eventos CHAT_MSG_* no listados -> activos por defecto
        if ChatEN_Channels[event] == nil and string.sub(event, 1, 9) == "CHAT_MSG_" then
            ChatEN_Channels[event] = true
            table.insert(ENTRA, event)
        end
        if ChatEN_Channels[event] == false then return end
        -- CHAT_MSG_CHANNEL: ademas del evento, control por nombre de canal (vararg 2)
        if event == "CHAT_MSG_CHANNEL" then
            local _, channelName = ...
            if channelName and channelName ~= "" then
                local v = ChatEN_ChannelNames[channelName]
                if v == nil then
                    ChatEN_ChannelNames[channelName] = true
                elseif v == false then
                    return
                end
            end
        end
        -- no retraducir los mensajes propios (ya salieron traducidos)
        local pname
        if UnitName then pname = UnitName("player") end
        if pname and type(author) == "string" and string.lower(author) == string.lower(pname) then return end
        local ok, es = pcall(Translate, msg, EN_T, "en")
        if not ok then
            Log("Filtro Translate: " .. tostring(es))
            return
        end
        if es ~= msg then
            -- modo comparacion: mostrar el mensaje original (color configurable)
            if origMode then
                local okA = pcall(function()
                    self:AddMessage("|cff" .. Hex(origC) .. "[orig] " .. msg .. "|r")
                end)
                if not okA then Log("AddMessage orig: " .. tostring(okA)) end
            end
            -- Este cliente (como BabelChat) interpreta los retornos del filtro
            -- como (flag, texto, autor, ...): false + la traduccion como 2do valor.
            -- En stock 3.3.5 false = sin cambios y el 2do valor se ignora (inofensivo).
            return false, "|cff" .. Hex(transC) .. es .. "|r", author, ...
        end
    end

    for _, e in ipairs(ENTRA) do
        ChatFrame_AddMessageEventFilter(e, ChatFilter)
    end

    -- Red amplia de diagnostico: eventos de chat NO traducibles (sistema, loot,
    -- BG, canales especiales) registrados solo para VER que llega. Si los canales
    -- del mundo de Ascension llegan por aqui, lo revela /chaten debug + log.
    local EXTRA = {
        "CHAT_MSG_BATTLEGROUND", "CHAT_MSG_BATTLEGROUND_LEADER",
        "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE", "CHAT_MSG_CHANNEL_LIST",
        "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER",
        "CHAT_MSG_AFK", "CHAT_MSG_DND", "CHAT_MSG_IGNORED", "CHAT_MSG_SYSTEM",
        "CHAT_MSG_LOOT", "CHAT_MSG_MONEY", "CHAT_MSG_SKILL",
        "CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_COMBAT_HONOR_GAIN", "CHAT_MSG_COMBAT_FACTION_CHANGE",
        "CHAT_MSG_BG_SYSTEM_NEUTRAL", "CHAT_MSG_BG_SYSTEM_HORDE", "CHAT_MSG_BG_SYSTEM_ALLIANCE",
        "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM",
    }
    local function DebugFilter(self, event, msg, author, ...)
        if debug and msg ~= nil then
            if type(msg) == "string" and msg ~= "" then
                Log("[CHAT] " .. tostring(event) .. " | " .. tostring(select(2, ...)) .. " | " .. string.sub(msg, 1, 40))
            elseif type(msg) == "table" then
                local parts = {}
                for k, v in pairs(msg) do
                    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
                    if #parts >= 8 then break end
                end
                Log("[CHAT] " .. tostring(event) .. " | TABLE: " .. table.concat(parts, ", "))
            end
        end
        -- tokens del servidor (LC1:CONF:...): ocultar en cualquier evento
        if type(msg) == "string" and string.match(msg, "^LC[1-5]:") then return true end
    end
    for _, e in ipairs(EXTRA) do
        ChatFrame_AddMessageEventFilter(e, DebugFilter)
    end

    -- Red final: el token LC puede llegar por un evento SIN filtro registrado.
    -- Interceptamos el handler global de chat y lo descartamos antes de mostrarse.
    if type(ChatFrame_MessageEventHandler) == "function" then
        local origMHE = ChatFrame_MessageEventHandler
        ChatFrame_MessageEventHandler = function(chatFrame, event, ...)
            local m = select(1, ...)
            DiagLine("MHE " .. tostring(event) .. "|" .. tostring(m) .. "|" .. tostring((select(2, ...))) .. "|" .. tostring((select(3, ...))))
            if type(m) == "string" and string.match(m, "^LC[1-5]:") then
                return
            end
            return origMHE(chatFrame, event, ...)
        end
    end

    -- Red final 2: si el cliente inyecta el token DIRECTAMENTE al frame de chat
    -- (sin pasar por eventos ni filtros), interceptarlo en ChatFrame_AddMessage,
    -- la funcion por la que pasa TODO texto que se muestra. Si el token viene
    -- pegado a un mensaje real, se quita el token y se muestra el texto limpio.
    local origAdd = ChatFrame_AddMessage or AddChatMessage
    if type(origAdd) == "function" then
        ChatFrame_AddMessage = function(frame, text, ...)
            DiagLine("ADD|" .. tostring(text) .. "|" .. tostring((select(1, ...))))
            if type(text) == "string" and string.match(text, "^LC[1-5]:") then
                local rest = string.gsub(text, "^LC[1-5]:[^%s]*%s?", "")
                if rest == "" then return end
                return origAdd(frame, rest, ...)
            end
            return origAdd(frame, text, ...)
        end
        if AddChatMessage and AddChatMessage ~= ChatFrame_AddMessage then
            AddChatMessage = ChatFrame_AddMessage
        end
    end

    -- Red final 3: el cliente puede inyectar el token por el METODO del frame
    -- (ChatFrame1:AddMessage) sin pasar por el global. Sombreamos el metodo.
    for i = 1, 40 do
        local f = _G["ChatFrame" .. i]
        if not f then break end
        local origM = f.AddMessage
        if type(origM) == "function" then
            f.AddMessage = function(self, text, ...)
                DiagLine("MADD|" .. tostring(text))
                if type(text) == "string" and string.match(text, "^LC[1-5]:") then
                    local rest = string.gsub(text, "^LC[1-5]:[^%s]*%s?", "")
                    if rest == "" then return end
                    return origM(self, rest, ...)
                end
                return origM(self, text, ...)
            end
        end
    end

    -- ── Tab: alternar traduccion saliente cuando el chat esta abierto ────────
    local editbox = ChatFrameEditBox
    local origTab = editbox and editbox:GetScript("OnTabPressed")
    if editbox then
        editbox:SetScript("OnTabPressed", function(self)
            enabled = not enabled
            ChatEN_Enabled = enabled
            if mmSetIcon then mmSetIcon() end
            print("|cff00ff00[ChatEN]|r Traduccion al ingles: " .. (enabled and "|cff40ff40ON|r" or "|cffff4040OFF|r"))
            if not enabled and origTab then
                origTab(self)
            end
        end)
    end

    -- ── Slash ───────────────────────────────────────────────────────────────
    SLASH_CHATEN1 = "/chaten"
    SlashCmdList["CHATEN"] = function(msg)
        msg = string.lower(msg:gsub("^%s*(.-)%s*$", "%1") or "")
        if msg == "off" then enabled = false ChatEN_Enabled = false print("ChatEN: desactivado") return end
        if msg == "on" then enabled = true ChatEN_Enabled = true print("ChatEN: activado") return end
        if msg == "ui" or msg == "ajustes" then if cfg then cfg:Show() end return end
        if msg == "log" then
            if #ChatEN_Log == 0 then print("|cff00ff00[ChatEN]|r Log vacio") return end
            for i = 1, #ChatEN_Log do
                print("|cffff4040[ChatEN]|r [" .. ChatEN_Log[i][1] .. "] " .. ChatEN_Log[i][2])
            end
            return
        end
        if msg == "clear" then ChatEN_Log = {} print("|cff00ff00[ChatEN]|r Log limpiado") return end
        if msg == "debug" then debug = not debug print("|cff00ff00[ChatEN]|r Debug " .. (debug and "ON (los eventos se guardan en /chaten log)" or "OFF")) return end
        if msg == "channels" then
            if not GetChannelDisplayInfo then print("|cff00ff00[ChatEN]|r API no disponible") return end
            local n = 0
            for i = 1, 40 do
                local name = GetChannelDisplayInfo(i)
                if not name then break end
                n = n + 1
                print("|cff00ff00[ChatEN]|r Canal " .. i .. ": " .. tostring(name))
            end
            print("|cff00ff00[ChatEN]|r " .. (n == 0 and "No hay canales unidos en este frame de chat" or n .. " canales unidos"))
            return
        end
        if msg == "reset" then
            for _, e in ipairs(ENTRA) do ChatEN_Channels[e] = true end
            ChatEN_ChannelNames = {}
            enabled = true
            print("|cff00ff00[ChatEN]|r Canales restablecidos (todos activos) y traduccion ON")
            return
        end
        print("ChatEN " .. (enabled and "activado" or "desactivado") .. " - /chaten on|off|log|clear|reset|debug|channels")
    end

    -- ── Icono del minimapa: click = on/off, click derecho = canales, arrastrar = mover ──
    ChatEN_MinimapAngle = ChatEN_MinimapAngle or 0
    local CH_NAMES = {
        ["CHAT_MSG_SAY"] = "Decir", ["CHAT_MSG_YELL"] = "Gritar",
        ["CHAT_MSG_PARTY"] = "Grupo", ["CHAT_MSG_PARTY_LEADER"] = "Lider de grupo",
        ["CHAT_MSG_RAID"] = "Bandada", ["CHAT_MSG_RAID_LEADER"] = "Lider de bandada",
        ["CHAT_MSG_RAID_WARNING"] = "Aviso de bandada",
        ["CHAT_MSG_GUILD"] = "Hermandad", ["CHAT_MSG_OFFICER"] = "Oficial",
        ["CHAT_MSG_WHISPER"] = "Susurro", ["CHAT_MSG_WHISPER_INFORM"] = "Susurro enviado",
        ["CHAT_MSG_CHANNEL"] = "Canal", ["CHAT_MSG_INSTANCE_CHAT"] = "Mazmorra",
        ["CHAT_MSG_INSTANCE_CHAT_LEADER"] = "Lider de mazmorra",
        ["CHAT_MSG_EMOTE"] = "Emote", ["CHAT_MSG_TEXT_EMOTE"] = "Emote de texto",
    }
    local mmOk, mmErr = pcall(function()
        local mm = CreateFrame("Button", "ChatENMinimapButton", Minimap)
        mm:SetFrameStrata("MEDIUM")
        mm:SetSize(36, 36)
        mm:SetMovable(true)
        mm:RegisterForDrag("LeftButton")
        mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local mtex = mm:CreateTexture(nil, "BACKGROUND")
        mtex:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        mtex:SetAllPoints()
        local angle = ChatEN_MinimapAngle
        local function Place()
            mm:ClearAllPoints()
            mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 78, math.sin(angle) * 78)
        end
        local function SetIcon()
            mtex:SetVertexColor(enabled and 0.2 or 1, enabled and 1 or 0.2, enabled and 0.2 or 1)
        end
        mmSetIcon = SetIcon
        Place()
        SetIcon()

        -- menu de canales (click derecho); 3.3.5: con keepShownOnClick el
        -- cliente marca la casilla solo y pasa su NUEVO estado como 4to arg
        local function ChannelMenu(self, level)
            local info
            for _, e in ipairs(ENTRA) do
                info = UIDropDownMenu_CreateInfo()
                info.text = (CH_NAMES[e] or e:gsub("CHAT_MSG_", "")) .. " (" .. e:gsub("CHAT_MSG_", "") .. ")"
                info.checked = ChatEN_Channels[e] ~= false
                info.func = function(_, _, _, checked)
                    if checked == nil then checked = ChatEN_Channels[e] ~= false end
                    ChatEN_Channels[e] = checked
                end
                info.keepShownOnClick = true
                UIDropDownMenu_AddButton(info, level)
            end
            info = UIDropDownMenu_CreateInfo()
            info.text = "|cff40ff40Todos"
            info.func = function() for _, e in ipairs(ENTRA) do ChatEN_Channels[e] = true end end
            UIDropDownMenu_AddButton(info, level)
            info = UIDropDownMenu_CreateInfo()
            info.text = "|cffff4040Ninguno"
            info.func = function() for _, e in ipairs(ENTRA) do ChatEN_Channels[e] = false end end
            UIDropDownMenu_AddButton(info, level)
            info = UIDropDownMenu_CreateInfo()
            info.text = "|cff40c0ffAjustes..."
            info.func = function() if cfg then cfg:Show() end end
            UIDropDownMenu_AddButton(info, level)
            -- canales personalizados detectados por nombre (CHAT_MSG_CHANNEL)
            local names = {}
            for name in pairs(ChatEN_ChannelNames) do names[#names + 1] = name end
            table.sort(names)
            if #names > 0 then
                info = UIDropDownMenu_CreateInfo()
                info.text = "Por nombre:"
                info.isTitle = true
                UIDropDownMenu_AddButton(info, level)
                for _, name in ipairs(names) do
                    info = UIDropDownMenu_CreateInfo()
                    info.text = name
                    info.checked = ChatEN_ChannelNames[name] ~= false
                    info.func = function(_, _, _, checked)
                        if checked == nil then checked = ChatEN_ChannelNames[name] ~= false end
                        ChatEN_ChannelNames[name] = checked
                    end
                    info.keepShownOnClick = true
                    UIDropDownMenu_AddButton(info, level)
                end
            end
        end
        -- patron 3.3.5: frame con plantilla + UIDropDownMenu_Initialize
        local menu = CreateFrame("Frame", "ChatENChannelMenu", nil, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(menu, ChannelMenu, "MENU")

        mm:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                ToggleDropDownMenu(1, nil, menu, self, 0, 0)
                return
            end
            enabled = not enabled
            ChatEN_Enabled = enabled
            SetIcon()
            print("|cff00ff00[ChatEN]|r " .. (enabled and "activado" or "desactivado"))
        end)
        mm:SetScript("OnDragStart", function(self) self:StartMoving() end)
        mm:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local mcx, mcy = Minimap:GetCenter()
            local x, y = self:GetCenter()
            if x and y and mcx and mcy then
                angle = math.atan2(y - mcy, x - mcx)
                ChatEN_MinimapAngle = angle
                Place()
            end
        end)
        if GameTooltip then
            mm:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:AddLine("ChatEN: " .. (enabled and "activado" or "desactivado"))
                GameTooltip:AddLine("Click: on/off | Click derecho: canales | Arrastrar: mover")
                GameTooltip:Show()
            end)
            mm:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end)
    if not mmOk then Log("Minimapa: " .. tostring(mmErr)) end

    -- ── Panel de ajustes ─────────────────────────────────────────────────────
    local cfgOk, cfgErr = pcall(function()
        local W, H = 440, 450
        cfg = CreateFrame("Frame", "ChatENConfig", UIParent)
        cfg:SetFrameStrata("DIALOG")
        cfg:SetSize(W, H)
        cfg:SetPoint("CENTER")
        cfg:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14, tile = true, tileSize = 14, insets = { left = 5, right = 5, top = 5, bottom = 5 } })
        cfg:SetBackdropColor(0.04, 0.04, 0.08, 0.88)
        cfg:EnableMouse(true)
        cfg:SetMovable(true)
        cfg:RegisterForDrag("LeftButton")
        cfg:SetScript("OnDragStart", function(self) self:StartMoving() end)
        cfg:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        cfg:Hide()

        local closeB = CreateFrame("Button", nil, cfg)
        closeB:SetSize(20, 20)
        closeB:SetPoint("TOPRIGHT", -10, -8)
        closeB:RegisterForClicks("LeftButtonUp")
        closeB:SetNormalTexture("Interface\\Buttons\\WHITE8X8")
        closeB:GetNormalTexture():SetVertexColor(0.55, 0.1, 0.1, 0.9)
        closeB:SetScript("OnClick", function() cfg:Hide() end)
        local closeT = closeB:CreateFontString(nil, "OVERLAY")
        closeT:SetFontObject(GameFontNormalLarge)
        closeT:SetPoint("CENTER")
        closeT:SetText("X")

        local title = cfg:CreateFontString(nil, "OVERLAY")
        title:SetPoint("TOP", 0, -12)
        title:SetFontObject(GameFontNormalLarge)
        title:SetText("|cffffd100ChatEN - Ajustes|r  |cff9f9f9fv2.14")

        local y = -44
        local function MkHeader(text)
            local h = cfg:CreateFontString(nil, "OVERLAY")
            h:SetPoint("TOPLEFT", 15, y)
            h:SetFontObject(GameFontNormalLarge)
            h:SetText("|cffffd100" .. text)
            y = y - 26
        end
        local function MkToggle(text, get, set)
            local b = CreateFrame("Button", nil, cfg)
            b:SetSize(W - 30, 24)
            b:RegisterForClicks("LeftButtonUp")
            b:SetPoint("TOPLEFT", 15, y)
            y = y - 30
            b:SetNormalTexture("Interface\\Buttons\\WHITE8X8")
            b:GetNormalTexture():SetVertexColor(0.12, 0.12, 0.18, 0.9)
            b:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight")
            b:SetNormalFontObject(GameFontNormalLarge)
            local function Paint()
                local on = get()
                b:SetText(text .. ": " .. (on and "|cff40ff40ON|r" or "|cffff4040OFF|r"))
            end
            local function OnClick()
                set(not get())
                Paint()
            end
            b:SetScript("OnClick", OnClick)
            Paint()
            return b, OnClick
        end

        MkHeader("Traducción")
        local toggleOut, ToggleOutClick = MkToggle("Traducir al escribir (es->en)",
            function() return enabled end,
            function(v) enabled = v ChatEN_Enabled = v if mmSetIcon then mmSetIcon() end end)
        local toggleOrig, ToggleOrigClick = MkToggle("Mostrar original + traducido",
            function() return origMode end,
            function(v) origMode = v ChatEN_ShowOriginal = v end)

        MkHeader("Colores del Chat")
        local bColorOrig, bColorTrans
        local okCol, colErr = pcall(function()
            local oi, ti = 1, 1
            for i, p in ipairs(PRESETS) do
                if p == origC then oi = i end
                if p == transC then ti = i end
            end
local function MkColor(text, c, save)
                local b = CreateFrame("Button", nil, cfg)
                b:SetSize(W - 30, 26)
                b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                b:SetPoint("TOPLEFT", 15, y)
                b:SetNormalTexture("Interface\\Buttons\\WHITE8X8")
                b:GetNormalTexture():SetVertexColor(0.12, 0.12, 0.18, 0.9)
                b:SetNormalFontObject(GameFontNormalLarge)
                b.cur = c
                -- texto en FontString propio: SetTextColor de FontString existe
                -- SIEMPRE (en Buttons algunos clientes custom no lo exponen)
                b.fs = b:CreateFontString(nil, "OVERLAY")
                b.fs:SetFontObject(GameFontNormalLarge)
                b.fs:SetPoint("LEFT", 6, 0)
                local function Paint()
                    b.fs:SetText(text)
                    b.fs:SetTextColor(b.cur[1], b.cur[2], b.cur[3])
                end
                function b:cycle()
                    local i
                    for n, p in ipairs(PRESETS) do if Hex(p) == Hex(self.cur) then i = n end end
                    i = (i or 0) % #PRESETS + 1
                    self.cur = PRESETS[i]
                    save(PRESETS[i])
                    Paint()
                end
                -- dropdown de colores si el template del cliente anda; si no,
                -- el boton cicla los 12 colores al click (siempre funciona)
                local menuOk, menuErr = pcall(function()
                    local menu = CreateFrame("Frame", "ChatENColorMenu" .. (text:find("original") and "Orig" or "Trans"), cfg, "UIDropDownMenuTemplate")
                    UIDropDownMenu_Initialize(menu, function(_, level)
                        local info
                        for i, p in ipairs(PRESETS) do
                            info = UIDropDownMenu_CreateInfo()
                            info.text = ("|cff%sColor %d|r"):format(Hex(p), i)
                            info.checked = Hex(b.cur) == Hex(p)
                            info.func = function()
                                b.cur = p
                                save(p)
                                Paint()
                            end
                            UIDropDownMenu_AddButton(info, level)
                        end
                    end, "MENU")
                    b:SetScript("OnClick", function()
                        ToggleDropDownMenu(1, nil, menu, b, 0, 0)
                    end)
                end)
                if not menuOk then
                    Log("Panel dropdown color: " .. tostring(menuErr))
                    b:SetScript("OnClick", function() b:cycle() end)
                end
                Paint()
                y = y - 30
                return b
            end
            bColorOrig = MkColor("Chat Original", origC,
                function(p) origC = p ChatEN_ColorOriginal = Hex(p) ChatEN_OrigColor = p
                    for i2, q in ipairs(PRESETS) do if q == p then oi = i2 end end end)
            bColorTrans = MkColor("ChatEN (Traducido)", transC,
                function(p) transC = p ChatEN_ColorTranslated = Hex(p) ChatEN_TransColor = p
                    for i2, q in ipairs(PRESETS) do if q == p then ti = i2 end end end)
        end)
        if not okCol then
            Log("Panel Colores: " .. tostring(colErr))
            local er = cfg:CreateFontString(nil, "OVERLAY")
            er:SetPoint("TOPLEFT", 15, y - 2)
            er:SetFontObject(GameFontNormalSmall)
            er:SetText("|cffff4040Error seccion colores: " .. tostring(colErr))
            y = y - 26
        end

        MkHeader("Diccionario y Frases Personalizadas")
        local labEs = cfg:CreateFontString(nil, "OVERLAY")
        labEs:SetPoint("TOPLEFT", 15, y - 2)
        labEs:SetFontObject(GameFontNormalSmall)
        labEs:SetText("|cff9f9f9fEspanol")
        local labEn = cfg:CreateFontString(nil, "OVERLAY")
        labEn:SetPoint("TOPLEFT", 229, y - 2)
        labEn:SetFontObject(GameFontNormalSmall)
        labEn:SetText("|cff9f9f9fIngles")
        y = y - 20

        local function MkBtn(text, w, fn, x)
            local b = CreateFrame("Button", nil, cfg)
            b:SetSize(w, 22)
            b:RegisterForClicks("LeftButtonUp")
            b:SetPoint("TOPLEFT", x or 15, y)
            b:SetNormalTexture("Interface\\Buttons\\UI-DialogBox-Button-Up")
            b:SetHighlightTexture("Interface\\Buttons\\UI-DialogBox-Button-Up")
            b:SetScript("OnClick", fn)
            local fs = b:CreateFontString(nil, "OVERLAY")
            fs:SetFontObject(GameFontNormalLarge)
            fs:SetPoint("CENTER")
            fs:SetText(text)
            b.Child = fs
            return b
        end
        local function MkEB(ph)
            local eb = CreateFrame("EditBox", nil, cfg)
            eb:SetSize(196, 22)
            eb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 4, right = 4, top = 2, bottom = 2 } })
            eb:SetBackdropColor(0.15, 0.15, 0.2, 0.9)
            eb:SetAutoFocus(false)
            eb:SetTextInsets(4, 4, 0, 0)
            eb:SetFontObject(GameFontNormalLarge)
            local phText = eb:CreateFontString(nil, "OVERLAY")
            phText:SetPoint("TOPLEFT", 7, -3)
            phText:SetFontObject(GameFontNormalSmall)
            phText:SetTextColor(0.55, 0.55, 0.6, 0.9)
            phText:SetText(ph)
            local function Upd()
                local t = eb:GetText()
                phText:SetShown(not t or t == "")
            end
            eb:SetScript("OnTextChanged", Upd)
            eb:SetScript("OnEnterPressed", function() AddFr() end)
            Upd()
            return eb
        end
        local eb1, eb2 = MkEB("Ej: manzana / hola como estas"), MkEB("Ej: apple / hello how are you")
        eb1:SetPoint("TOPLEFT", 15, y)
        eb2:SetPoint("TOPLEFT", 229, y)
        y = y - 26

        local st = cfg:CreateFontString(nil, "OVERLAY")
        st:SetPoint("TOPLEFT", 140, y - 3)
        st:SetWidth(W - 160)
        st:SetJustifyH("LEFT")
        st:SetFontObject(GameFontNormalSmall)
        local function SetSt(msg) st:SetText(msg) end
        y = y - 24

        local function frValue(eb)
            return tostring(eb.t or eb:GetText() or ""):gsub("^%s*(.-)%s*$", "%1")
        end
        local RebuildList
        local function AddFr()
            local k, v = frValue(eb1), frValue(eb2)
            if k == "" or v == "" or k == v then
                SetSt("|cffff4040Escribi la palabra y su traduccion (distintas)")
                return
            end
            ChatEN_Custom[k] = v
            eb1:SetText("")
            eb2:SetText("")
            SetSt("|cff40ff40Agregada: " .. k .. " -> " .. v .. "  |cff9f9f9f(/reload la guarda ya)")
            RebuildList()
        end
        local function DelFr()
            local k = frValue(eb1)
            if k == "" then SetSt("|cffff4040Escribi la palabra a eliminar") return end
            if ChatEN_Custom[k] then
                ChatEN_Custom[k] = nil
                SetSt("|cff40ff40Eliminada: " .. k)
                RebuildList()
            else
                SetSt("|cff40ff40No estaba: " .. k)
            end
        end
        local function ListFr()
            local n = 0
            for k, v in pairs(ChatEN_Custom) do
                n = n + 1
                if n > 15 then
                    print("|cff00ff00[ChatEN]|r ... y " .. (n - 15) .. " mas")
                    break
                end
                print("|cff00ff00[ChatEN]|r " .. tostring(k) .. " -> " .. tostring(v))
            end
            if n == 0 then print("|cff00ff00[ChatEN]|r No hay frases propias todavia") end
        end

        MkBtn("Agregar", 110, function() AddFr() end, 15)
        y = y - 28

        local lhEs = cfg:CreateFontString(nil, "OVERLAY")
        lhEs:SetPoint("TOPLEFT", 19, y - 2)
        lhEs:SetFontObject(GameFontNormalSmall)
        lhEs:SetText("|cff9f9f9fEspanol")
        local lhEn = cfg:CreateFontString(nil, "OVERLAY")
        lhEn:SetPoint("TOPLEFT", 189, y - 2)
        lhEn:SetFontObject(GameFontNormalSmall)
        lhEn:SetText("|cff9f9f9fIngles")
        local lhAc = cfg:CreateFontString(nil, "OVERLAY")
        lhAc:SetPoint("TOPLEFT", W - 80, y - 2)
        lhAc:SetFontObject(GameFontNormalSmall)
        lhAc:SetText("|cff9f9f9fAcciones")
        y = y - 16

        local list = CreateFrame("ScrollFrame", "ChatENDictScroll", cfg, "UIPanelScrollFrameTemplate")
        list:SetPoint("TOPLEFT", 15, y)
        list:SetSize(W - 52, 132)
        local content = CreateFrame("Frame", nil, list)
        list:SetScrollChild(content)
        local rows = {}
        local function MakeRow(i)
            local row = CreateFrame("Frame", nil, content)
            row:SetSize(W - 66, 16)
            row:SetPoint("TOPLEFT", 2, -(i - 1) * 16)
            row.fsEs = row:CreateFontString(nil, "OVERLAY")
            row.fsEs:SetFontObject(GameFontNormalSmall)
            row.fsEs:SetPoint("TOPLEFT", 2, 0)
            row.fsEs:SetWidth(160)
            row.fsEs:SetJustifyH("LEFT")
            row.fsEn = row:CreateFontString(nil, "OVERLAY")
            row.fsEn:SetFontObject(GameFontNormalSmall)
            row.fsEn:SetPoint("TOPLEFT", 172, 0)
            row.fsEn:SetWidth(150)
            row.fsEn:SetJustifyH("LEFT")
            local del = CreateFrame("Button", nil, row)
            del:SetSize(16, 16)
            del:RegisterForClicks("LeftButtonUp")
            del:SetPoint("RIGHT", -2, 0)
            del:SetNormalTexture("Interface\\Buttons\\WHITE8X8")
            del:GetNormalTexture():SetVertexColor(0.55, 0.1, 0.1, 0.9)
            local dtx = del:CreateFontString(nil, "OVERLAY")
            dtx:SetFontObject(GameFontNormalSmall)
            dtx:SetPoint("CENTER")
            dtx:SetText("X")
            del:SetScript("OnClick", function()
                local k = row.k
                if k and ChatEN_Custom[k] then
                    ChatEN_Custom[k] = nil
                    SetSt("|cff40ff40Eliminada: " .. k)
                    RebuildList()
                end
            end)
            rows[i] = row
            return row
        end
        RebuildList = function()
            local keys = {}
            for k in pairs(ChatEN_Custom) do keys[#keys + 1] = k end
            table.sort(keys)
            local n = math.min(#keys, 150)
            for i = 1, n do
                local row = rows[i] or MakeRow(i)
                local k = keys[i]
                row:Show()
                row.k = k
                row.fsEs:SetText(#k > 22 and k:sub(1, 21) .. "..." or k)
                local v = tostring(ChatEN_Custom[k])
                row.fsEn:SetText(#v > 20 and v:sub(1, 19) .. "..." or v)
            end
            for i = n + 1, #rows do rows[i]:Hide() end
            content:SetSize(W - 66, math.max(n, 1) * 16)
        end
        RebuildList()

        ChatEN_UI = {
            show = function() cfg:Show() end,
            add = AddFr,
            del = DelFr,
            list = ListFr,
            toggleOut = ToggleOutClick,
            toggleOrig = ToggleOrigClick,
            cycleOrig = function() if bColorOrig then bColorOrig:cycle() end end,
            cycleTrans = function() if bColorTrans then bColorTrans:cycle() end end,
            setFields = function(f1, f2) if eb1 and eb2 then eb1.t, eb2.t = f1, f2 end end,
        }
    end)
    if not cfgOk then Log("Panel ajustes: " .. tostring(cfgErr)) end

end, function(e)
    local stack = ""
    if pcall(debugstack) then stack = "\n" .. debugstack(2) end
    return tostring(e) .. stack
end)

if not okInit then
    Log("ERROR CARGA: " .. initErr)
    -- el chat todavia no existe en la carga: avisar al entrar
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        print("|cffff4040[ChatEN] ERROR al cargar (ver /chaten log):|r " .. tostring(ChatEN_Log[#ChatEN_Log][2]):gsub("\n.*", ""))
        f:UnregisterEvent("PLAYER_LOGIN")
    end)
end
