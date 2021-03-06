report = (msg) ->
  atom.notifications?.addError msg
  console.log msg

operators = {
  c: 'command'
  k: 'key'
  s: 'selector'
}

clone = (o) ->
  r = {}
  for k in Object.keys(o)
    r[k] = o[k]
  r

module.exports =

  activate: ->
    @regex_cache = {}

  deactivate: ->
    @regex_cache = null

  getDynamicMode: (name, source) ->
    unless (m = /^([+-])([cks])(.)/.exec name)?
      return null
    action = m[1]
    operation = operators[m[2]]
    name = name.substr(3)
    unless (n = (r = @getRegexWithSeparator(m[3])).exec name)?
      return null
    match = n[1]
    name = name.substr(n[1].length + 1)
    if (n = r.exec name)?
      substitute = n[1]
      name = name.substr(n[1].length + 1)
    if name is ''
      return @getSpecial(['!' + action, operation, match, substitute], source)
    else
      return null

  getSpecial: (inh, source) ->
    source.flags.no_filter = true
    action = inh[0]
    operator = inh[1]
    operator = 'keystrokes' if operator is 'key'
    match = inh[2]
    substitute = inh[3]
    keymap = {}
    matching_regex = new RegExp(match)
    for keybinding in source.getKeyBindings()
      keybinding = clone keybinding
      if substitute?
        matched = false
        n = keybinding[operator].replace matching_regex, (match, m..., offset, string) ->
          matched = true
          s = substitute
          s = s.replace "$#{i+1}", v for v, i in m
          s
        continue unless matched
        if action is '!-'
          keymap[keybinding.selector] ?= {}
          keymap[keybinding.selector][keybinding.keystrokes] = 'unset!'
        keybinding[operator] = n
        keymap[keybinding.selector] ?= {}
        keymap[keybinding.selector][keybinding.keystrokes] = keybinding.command
      else
        if (matching_regex.test keybinding[operator]) ^ (source.flags.not is true)
          keymap[keybinding.selector] ?= {}
          if action isnt '!-'
            keymap[keybinding.selector][keybinding.keystrokes] = keybinding.command
          else
            keymap[keybinding.selector][keybinding.keystrokes] = 'unset!'
    source.flags.resolved = true
    return keymap: keymap

  isValidMode: (_name) ->
    name = _name
    unless (m = /^([+-])([cks])(.)/.exec name)?
      report "Couldn't match regex start #{name} in #{_name}"
      return false
    name = name.substr(3)
    unless (n = (r = @getRegexWithSeparator(m[3])).exec name)?
      report "Couldn't match regex body #{name} in #{_name}"
      return false
    name = name.substr(n[1].length + 1)
    if (n = r.exec name)?
      name = name.substr(n[1].length + 1)
    unless name is ''
      report "Couldn't match substitution regex #{name} in #{_name}"
      return false
    return true

  isSpecial: (inh) ->
    return false if inh.length < 3
    return false unless inh[1] in ['key', 'selector', 'command']
    return false unless typeof inh[2] is 'string'
    return false if inh[3]? and typeof inh[3] isnt 'string'
    return true

  getRegexWithSeparator: (sep) ->
    return @regex_cache[sep] if @regex_cache[sep]?
    @regex_cache[sep] = new RegExp("^([^#{sep}]*?)#{sep}")
