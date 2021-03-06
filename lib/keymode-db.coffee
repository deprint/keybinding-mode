{Emitter, CompositeDisposable} = require 'atom'

extensions = require './extensions'
dynamicModes = require './dynamic-modes'
regexModes = require './regex-modes'
serviceModes = require './service-modes'

crypto = require('crypto')

path = require 'path'
fs = require 'fs'

CSON = require 'season'

_ = require('underscore-plus')

debug = (type, obj) ->
  console.log {type, obj} if atom.config.get('keybinding-mode.debugger')

suppressed = false

report = (msg) ->
  atom.notifications?.addError msg unless suppressed
  console.log msg

pick = (o, f) ->
  r = {}
  for k in Object.keys(o)
    r[k] = o[k] if f(k)
  return r

merge = (dest, source) ->
  return unless dest?
  return unless source?
  return if source is '!all'
  dest.keymap = {} unless dest.keymap?
  if source.keymap?
    for selector in Object.keys(source.keymap)
      if dest.keymap[selector]?
        for key in Object.keys(source.keymap[selector])
          dest.keymap[selector][key] = source.keymap[selector][key]
      else
        dest.keymap[selector] = _.clone source.keymap[selector]
  if dest.execute and source?.execute
    dest.execute = ((x, y) -> (r) -> x r; y r)(dest.execute, source.execute)
  else if source?.execute
    dest.execute = source.execute

filter = (dest, source, invert = false) ->
  return if source is '!all' and not invert
  if invert
    if source is '!all'
      all = {}
      source = keymap: all
      for {selector, keystrokes, command} in atom.keymaps.getKeyBindings()
        all[selector] ?= {}
        all[selector][keystrokes] = command
    m = {}
    for k in Object.keys(source.keymap)
      if dest.keymap[k]?
        s = {}
        for k2 in Object.keys(source.keymap[k])
          s[k2] = source.keymap[k][k2] unless dest.keymap[k][k2]?
        m[k] = s if Object.keys(s).length isnt 0
      else
        m[k] = _.clone(source.keymap[k])
    dest.keymap = m
  else
    dest.keymap = pick dest.keymap, (k) ->
      return false unless source.keymap[k]?
      dest.keymap[k] = pick dest.keymap[k], (k2) ->
        return source.keymap[k][k2]?
      return Object.keys(dest.keymap[k]).length isnt 0

diff = (mode) ->
  m = mode.keymap
  all = {}
  for {selector, keystrokes, command} in atom.keymaps.getKeyBindings()
    all[selector] ?= {}
    all[selector][keystrokes] = command

  for s in Object.keys m
    selector = m[s]
    for k in Object.keys selector
      exists = all[s]?[k]?
      if ((not exists) and selector[k] is 'unset!') or all[s]?[k] is selector[k]
        delete selector[k]
    if Object.keys(selector).length is 0
      delete m[s]
  return mode

getKeyBindings = ->
  return atom.keymaps.getKeyBindings() if @source is '!all'
  keymap = @source.keymap
  r = []
  for selector in Object.keys keymap
    for keystrokes in Object.keys keymap[selector]
      r.push {selector, keystrokes, command: keymap[selector][keystrokes]}
  r

plusKeymap = (sobj) ->
  sobj.flags.no_filter = true
  keymap = {}
  for keybinding in sobj.getKeyBindings()
    keymap[keybinding.selector] ?= {}
    keymap[keybinding.selector][keybinding.keystrokes] = keybinding.command
  return {keymap}

minusKeymap = (sobj) ->
  sobj.flags.no_filter = true
  keymap = {}
  for keybinding in sobj.getKeyBindings()
    keymap[keybinding.selector] ?= {}
    keymap[keybinding.selector][keybinding.keystrokes] = 'unset!'
  return {keymap}

resolveLocalKeymap = (callback, arr_in = atom.project.getPaths(), arr_out = []) ->
  return callback(arr_out) if arr_in.length is 0
  fs.exists (f = path.join(arr_in.shift(), '.advanced-keybindings.cson')), (exists) ->
    arr_out.push f if exists
    resolveLocalKeymap callback, arr_in, arr_out

module.exports =
  modes: {} # Stores keybinding modes
  mode_subscription: null # Stores atom.commands.add bindings
  key_subscription: null # Stores current keybinding subscription
  current_keymap: null # Stores current keymap name
  emitter: null

  activate: ->
    if atom.inSpecMode()
      @merge = merge
      @filter = filter
    @emitter = new Emitter
    extensions.activate(this)
    regexModes.activate()
    serviceModes.activate(this)
    @scheduledReload = null
    @names = []

  deactivate: ->
    @scheduledReload = null
    @modes = {}
    @names = []
    @mode_subscription?.dispose()
    @mode_subscription = null
    @deactivateKeymap @current_keymap if @current_keymap?
    extensions.deactivate()
    regexModes.deactivate()
    serviceModes.deactivate()
    @emitter?.dispose()
    @emitter = null

  onReload: (cb) ->
    @emitter.on 'reload', cb

  onAppend: (cb) ->
    @emitter.on 'append', cb

  onToggle: (cb) ->
    @emitter.on 'toggle', cb

  onDeactivate: (cb) ->
    @emitter.on 'deactivate', cb

  onActivate: (cb) ->
    @emitter.on 'activate', cb

  reload: (f) ->
    unless f?
      f = path.join(path.dirname(atom.config.getUserConfigPath()), 'keybinding-mode.cson')
    @deactivateKeymap() if @current_keymap?
    @mode_subscription?.dispose()
    @mode_subscription = new CompositeDisposable
    @modes = {}
    @names = []
    new Promise((resolve, reject) =>
      @appendFile(f).then(=>
        @resolveAutostart().then((name) =>
          @emitter.emit 'reload', name
          resolve()
        , reject)
      , reject)
    )

  toggleKeymap: (name) ->
    if name is @current_keymap?.name
      @deactivateKeymap()
    else
      @deactivateKeymap() if @current_keymap?
      @activateKeymap name
      @emitter.emit 'toggle', name

  deactivateKeymap: ->
    @current_keymap.execute?(true)
    @key_subscription?.dispose()
    name = @current_keymap.name
    @current_keymap = null
    @emitter.emit 'deactivate', name

  activateKeymap: (name) ->
    @current_keymap =
      name: name
    @current_keymap.mode = @resolveWithTest(name)
    unless @current_keymap.mode?
      console.log "Could not resolve #{name}"
      @current_keymap = null
      return
    @current_keymap.mode.execute?()
    @key_subscription = atom.keymaps.add 'keybinding-mode:' + name, @current_keymap.mode.keymap
    @emitter.emit 'activate', name

  appendFile: (file) ->
    new Promise((resolve, reject) =>
      fs.exists file, (exists) =>
        return reject('Advanced keymap does not exist: ' + file) unless exists
        CSON.readFile file, (error, contents) =>
          if error? or not contents?
            report 'Could not read ' + file
            reject 'Could not read ' + file
            return
          command_map = {}
          autostart = null
          promises = []
          for mode in Object.keys contents
            if mode is '!autostart'
              autostart = contents[mode]
              continue
            else if mode is '!import'
              unless contents[mode] instanceof Array
                report('!import must be an array of file paths')
                continue
              for next_file in contents[mode]
                unless (typeof file) is 'string'
                  report('File path must be string: ' + file)
                  continue
                promises.push @appendFile(path.resolve(path.dirname(file), next_file))
              continue
            else if contents[mode] instanceof Array
              contents[mode].splice(0, 0, '!all')
            else
              contents[mode] = ['!all', contents[mode]]
            @modes[mode] =
              inherited: contents[mode]
              resolved: false
              execute: null
              keymap: null
            @names.push mode
            if mode[0] isnt '.'
              command_map['keybinding-mode:' + mode] = @getCommandFunction mode
          Promise.all(promises).then(=>
            if autostart?
              if autostart instanceof Array
                contents['!autostart'] = autostart
                contents['!autostart'].splice(0, 0, '!all')
              else
                contents['!autostart'] = ['!all', autostart]
              @modes['!autostart'] =
                inherited: contents['!autostart']
                resolved: false
                execute: null
                keymap: null
            if Object.keys(command_map) isnt 0
              @mode_subscription.add atom.commands.add 'atom-workspace', command_map
            @emitter.emit 'append', file
            resolve()
          , reject)
    )

  addCommands: (modes, ignore) ->
    s = []
    sn = @getStaticNames(ignore)
    s.push mode for mode in modes when not sn[mode]? and mode[0] isnt '.'
    command_map = {}
    for mode in s
      command_map['keybinding-mode:' + mode] = @getCommandFunction mode
    return atom.commands.add 'atom-workspace', command_map

  getCommandFunction: (mode) ->
    ((_this, name) -> -> _this.toggleKeymap(name))(this, mode)

  scheduleReload: ->
    return if @scheduledReload?
    @scheduledReload = setTimeout(=>
      @scheduledReload = null
      @reload()
    , atom.config.get('keybinding-mode.delay'))

  resolveAutostart: ->
    new Promise((resolve, reject) =>
      resolveLocalKeymap (files) =>
        p = []
        for file in files
          p.push @appendFile(file)
        Promise.all(p).then(=>
          return resolve('default') unless @modes['!autostart']?
          suppressed = true
          if (@modes['!autostart'].inherited.length is 2) and (typeof @modes['!autostart'].inherited[1]) is 'string' and @isStatic(@modes['!autostart'].inherited[1])
            @activateKeymap @modes['!autostart'].inherited[1]
            suppressed = false
            resolve(@modes['!autostart'].inherited[1])
          else
            @activateKeymap '!autostart'
            suppressed = false
            resolve('!autostart')
        , (e) ->
          suppressed = false
          reject(e)
        )
    )

  resolveWithTest: (name) ->
    return @modes[name] if @modes[name]?.resolved
    return unless @dryRun name
    m = diff(@_resolve name)
    if atom.config.get('keybinding-mode.debugger')
      CSON.writeFileSync path.join(path.dirname(atom.config.getUserConfigPath()), 'keybinding-mode-dump.cson'), m.keymap
    return m

  resolve: (name, sobj) ->
    return @modes[name] if @modes[name]?.resolved
    return @_resolve name, sobj

  _resolve: (name, _sobj) ->
    inh = @modes[name].inherited.slice()
    inh = @replacePatterns inh, name
    _sobj ?= {is_static: true, directives: {}, flags: {}}
    if inh.length > 1
      source = @getSource inh.shift(), _sobj
    else if _sobj.source?
      source = _sobj.source
    else
      source = '!all'
    debug 'source', source
    debug 'inh', inh
    for i in inh
      sobj = {
        source
        getKeyBindings
        filter
        merge
        is_static: false
        flags: {no_filter: false}
        directives: _.clone _sobj.directives
      }
      @resolveFilter @modes[name], i, sobj, _sobj
    @modes[name].resolved = _sobj.is_static
    return @modes[name]

  resolveMode: (i, _sobj) ->
    mode = keymap: {}
    @resolveFilter mode, i, _sobj, _sobj
    return mode

  resolveFilter: (mode, i, sobj, _sobj) ->
    if (typeof i) is 'string'
      if @isStatic i
        m = @getStatic i, sobj
      else
        m = @getDynamic i, sobj
    else if i instanceof Array
      if @isSpecial i
        m = @getSpecial i, sobj
      else
        m = @process i, sobj
    else
      sobj.is_static = _sobj.is_static
      m = i
    _sobj.is_static = false unless sobj.is_static
    debug 'pre-filter', {i, m}
    unless sobj.flags.no_filter
      filter m, sobj.source, (sobj.flags.not is true)
      debug 'post-filter', m
    else
      debug 'no-filter', m
    merge mode, m
    debug 'post-merge', {mode: mode, m}

  cloneSourceObject: (inh) ->
    sobj = _.clone(inh)
    sobj.is_static = false
    sobj.flags = {no_filter: false}
    sobj.directives = _.clone inh.directives
    return sobj

  getSource: (inh, sobj) ->
    return inh if inh is '!all'
    return @resolveMode inh, sobj

  isStatic: (inh) ->
    return not /^[!+-]/.test inh[0]

  getStatic: (inh, sobj) ->
    if (@modes[inh])?
      sobj.is_static = true
      return @resolve inh, sobj
    if (m = extensions.getStatic inh, sobj)?
      @modes[inh] = inherited: m
      return @resolve inh, sobj
    if (m = serviceModes.getStaticMode inh, sobj)?
      @modes[inh] = inherited: m
      return @resolve inh, sobj
    report "Assertion: getStatic must work on #{inh}"
    return null

  getDynamic: (name, sobj) ->
    return plusKeymap(sobj) if name is '+'
    return minusKeymap(sobj) if name is '-'
    if extensions.isValidMode name
      inh = extensions.getDynamic name, sobj
      return inh if sobj.flags.resolved is true
      return @resolveMode inh, sobj
    if serviceModes.isValidMode name
      inh = serviceModes.getDynamicMode name, sobj
      return inh if sobj.flags.resolved is true
      return @resolveMode inh, sobj
    if dynamicModes.isValidMode name
      inh = dynamicModes.getDynamicMode name, sobj
      return inh if sobj.flags.resolved is true
      return @resolveMode inh, sobj
    if regexModes.isValidMode name
      inh = regexModes.getDynamicMode name, sobj
      return inh if sobj.flags.resolved is true
      return @resolveMode inh, sobj
    report "Assertion: getDynamic must work on #{name}"
    return null

  getSpecial: (inh, sobj) ->
    if (m = extensions.getSpecial inh, sobj)?
      return m if sobj.flags.resolved is true
      return @resolveMode m, sobj
    if (m = regexModes.getSpecial inh, sobj)?
      return m if sobj.flags.resolved is true
      return @resolveMode m, sobj
    report "Assertion: getSpecial must work on #{inh}"
    return null

  replacePatterns: (mode, name) ->
    m = []
    for inh in mode
      if @isPattern inh
        m = m.concat @getStaticModes inh, name
      else if (inh instanceof Array) and @isCombined inh
        m.push @getCombined inh.slice()
      else
        m.push inh
    return m

  getStaticModes: (inh, name) ->
    if inh is '~'
      inh = "~^\.?#{name}-"
    r = new RegExp(inh.substr(1))
    return (mode for mode in Object.keys(@getStaticNames()) when r.test(mode) and mode isnt name)

  process: (inh, sobj) ->
    sobj.flags.no_filter = true
    name = @getName inh
    @modes[name] = inherited: inh
    @resolve name, sobj

  getName: (name, init = false) ->
    if (typeof name) is 'string'
      @modes[name] = {} if init
      return name
    md5 = crypto.createHash('md5')
    md5.update(JSON.stringify(name), 'utf8')
    m = md5.digest('hex')
    @modes[m] = {} if init
    return m

  getCombined: (inh) ->
    a = inh.shift()
    op = inh.shift()
    b = inh
    b = inh[0] if b.length is 1

    if a instanceof Array and @isCombined a
      a = @getCombined a
    if b instanceof Array and @isCombined b
      b = @getCombined b

    if op is '&'
      return [a, b]
    else
      return ['!all', a, b]

  getStaticNames: (ignore = 0) ->
    modes = {}
    modes[k] = true for k in @names
    modes[k] = true for k in extensions.getStaticNames() if ignore isnt 2
    modes[k] = true for k in serviceModes.getStaticNames() if ignore isnt 1
    return modes

  dryRun: (name) ->
    mode = @modes[name]
    return false unless mode?
    return true if mode?.resolved
    return @_dryRun mode.inherited

  _dryRun: (inh) ->
    if (typeof inh) is 'string'
      return @validMode inh
    else if inh instanceof Array
      return @validSpecial inh if @isSpecial inh
      return @validCombined inh if @isCombined inh
      if inh.length is 0
        report 'Empty array not allowed'
        return false
      else if inh.length is 1
        report 'One-element-array not allowed'
        return false
      return false for i in inh when not @_dryRun i
    else
      unless inh.keymap or inh.execute
        report "Object #{inh} does not contain keymap or function"
        return false
    return true

  isCombined: (inh) ->
    for i in inh
      return true if (typeof i) is 'string' and /^[&|]$/.test i
    return false

  isSpecial: (inh) ->
    return (typeof inh[0]) is 'string' and inh[0][0] is '!' and inh[0] isnt '!all'

  isPattern: (inh) ->
    return (typeof inh) is 'string' and inh[0] is '~'

  validMode: (name) ->
    return true if name is '!all'
    return true if @isPattern name
    return true if @modes[name]?
    return true if extensions.isValidMode name
    return true if serviceModes.isValidMode name
    return true if dynamicModes.isValidMode name
    return true if regexModes.isValidMode name
    return false

  validSpecial: (inh) ->
    return true if extensions.isSpecial inh
    return true if regexModes.isSpecial inh
    report "#{inh} is not a valid special form"
    return false

  validCombined: (inh) ->
    next_is_filter = true
    for i in inh
      if next_is_filter
        return false unless @_dryRun i
      else
        unless (typeof i) is 'string' and /^[&|]$/.test i
          report "#{i} supposed to be operator"
          return false
      next_is_filter = not next_is_filter
    return true
