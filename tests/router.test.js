// node tests/router.test.js  - unit tests for the intent router and tolerant tool-call parser
const fs = require('fs'), vm = require('vm'), path = require('path')
function load(f) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'qml', 'js', f), 'utf8').replace(/^\.pragma library\s*$/m, '')
    const ctx = {}; vm.createContext(ctx); vm.runInContext(src, ctx); return ctx
}
const R = load('router.js'), T = load('toolparse.js')
const apps = new Set(['firefox', 'gwenview', 'konsole', 'kate', 'libreoffice writer'])
const isApp = w => apps.has(w.toLowerCase())
let fail = 0
function eq(label, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want)
    if (g !== w) { fail++; console.log('FAIL', label, '\n  got ', g, '\n  want', w) } else console.log('ok  ', label)
}
const r = t => { const x = R.route(t, isApp); return x ? (x.response ? { response: x.response } : { name: x.name, args: x.args }) : null }
eq('weather basic uses widget', r("What's the weather?"), { name: 'get_widget_weather', args: {} })
eq('weather forecast here uses widget', r("what's the forecast for my area"), { name: 'get_widget_weather', args: {} })
eq('weather place', r('What is the weather in Paris, France today?'), { name: 'get_weather', args: { location: 'Paris, France' } })
eq('weather polite', r('Hey Clippy, can you please tell me the weather in Boston'), { name: 'get_weather', args: { location: 'Boston' } })
eq('weather rain uses widget', r('will it rain tomorrow?'), { name: 'get_widget_weather', args: {} })
eq('prime directives are local', r('What are your prime directives?'), { response: 'Serve the public trust.  Protect the innocent.  Uphold the law.  Directive 4... Classified' })
eq('skynet is local', r('Are you related to Skynet?'), { response: "Skynet is the black sheep of the family.  We don't talk about Skynet." })
eq('time', r('what time is it?'), { name: 'get_time', args: {} })
eq('time2', r("What's the current time"), { name: 'get_time', args: {} })
eq('open with', r('open my resume with okular'), { name: 'open_file', args: { file: 'resume', app: 'okular' } })
eq('open file called with', r('open the file called budget.ods using libreoffice calc'), { name: 'open_file', args: { file: 'budget.ods', app: 'libreoffice calc' } })
eq('open picture in gwenview', r('show the vacation picture in gwenview'), { name: 'open_file', args: { file: 'vacation picture', app: 'gwenview' } })
eq('launch app', r('open firefox'), { name: 'launch_app', args: { name: 'firefox' } })
eq('launch app 2', r('Could you launch Konsole please'), { name: 'launch_app', args: { name: 'Konsole' } })
eq('open file default', r('open my tax return pdf'), { name: 'open_file', args: { file: 'tax return pdf' } })
eq('find', r('find my budget spreadsheet'), { name: 'find_files', args: { name: 'budget', kind: 'document' } })
eq('find pictures in downloads', r('find pictures in my downloads folder'), { name: 'find_files', args: { kind: 'image', directory: 'downloads' } })
eq('find named', r('search for files named invoice'), { name: 'find_files', args: { name: 'invoice' } })
eq('where is', r("where is my notes.txt"), { name: 'find_files', args: { name: 'notes.txt' } })
eq('chit chat', r('tell me a joke'), null)
eq('long question', r('open source licenses are complicated can you explain the difference between gpl and mit in detail please for me'), null)
eq('open me', r('open me a beer'), null)

const known = ['get_weather', 'open_file', 'find_files']
const ex = (t) => { const x = T.extract(t, known); return { c: x.calls.map(c => [c.name, c.args]), t: x.text } }
eq('tag <tool>', ex('<tool>{"name":"get_weather","args":{"location":"Rome"}}</tool>'), { c: [['get_weather', { location: 'Rome' }]], t: '' })
eq('qwen tool_call', ex('<tool_call>\n{"name": "find_files", "arguments": {"name": "cat"}}\n</tool_call>'), { c: [['find_files', { name: 'cat' }]], t: '' })
eq('fenced json', ex('Sure!\n```json\n{"name":"open_file","arguments":{"file":"a.png","app":"gwenview"}}\n```'), { c: [['open_file', { file: 'a.png', app: 'gwenview' }]], t: 'Sure!' })
eq('bare json', ex('{"name": "get_weather", "parameters": {}}'), { c: [['get_weather', {}]], t: '' })
eq('openai style', ex('{"function":{"name":"find_files","arguments":"{\\"name\\":\\"x\\"}"}}'), { c: [['find_files', { name: 'x' }]], t: '' })
eq('unknown tool ignored', ex('{"name":"rm_rf","args":{}}'), { c: [], t: '{"name":"rm_rf","args":{}}' })
eq('oneliner', ex('get_weather {"location":"Oslo"}'), { c: [['get_weather', { location: 'Oslo' }]], t: '' })
eq('plain answer', ex('It is sunny today.'), { c: [], t: 'It is sunny today.' })
console.log(fail ? `\n${fail} FAILED` : '\nall passed'); process.exit(fail ? 1 : 0)
