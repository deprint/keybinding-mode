{Disposable} = require 'atom'

report = (msg) ->
  atom.notifications?.addError msg
  console.log msg

module.exports =

  activate: (@db) ->
    @extensions = {}
    @static_ext = {}
    @dynamic_ext = {}
    @special_ext = {}

  deactivate: ->
    @remove name for name in Object.keys(@extensions)
    @extensions = null
    @static_ext = null
    @dynamic_ext = null
    @special_ext = null
    @db = null

  remove: (name) ->
    return unless @extensions[name]?
    @static_ext[ext] = null for ext in @extensions[name].static
    @dynamic_ext[ext] = null for ext in @extensions[name].dynamic
    @special_ext[ext] = null for ext in @extensions[name].special
    ext.deactivate?() for ext in @extensions[name].all
    delete @extensions[name]

  consume: ({name, extensions}) ->
    unless name?
      report 'Service did not provide name'
      return
    unless extensions?
      report 'Service did not provide any extensions'
      return
    unless (typeof extensions) is 'object'
      report 'Service\'s extensions is not an object'
      return
    if @extensions[name]?
      report "Service #{name} already exists"
      return
    r =
      static: []
      dynamic: []
      special: []
      all: []
    for e in Object.keys(extensions)
      extension = extensions[e]

      unless extension.getStaticMode? or extension.getDynamicMode? or extension.getSpecial?
        report "Extension #{e} provides nothing"
        continue

      if extension.getStaticMode? or extension.getDynamicMode?
        unless extension.isValidMode?
          report "Extension #{e} must provide ::isValidMode(name)"
          continue

      if extension.getSpecial?
        unless extension.isSpecial?
          report "Extension #{e} must provide ::isSpecial(inh)"
          continue

      if extension.getStaticMode? and extension.getDynamicMode?
        unless extension.isStaticMode?
          report "Extension #{e} must provide ::isStaticMode(name)"
          continue
      else if extension.getStaticMode?
        extension.isStaticMode = -> true
      else if extension.getDynamicMode?
        extension.isStaticMode = -> false

      r.all.push extension
      if extension.getStaticMode?
        r.static.push e
        @static_ext[e] = extension
      if extension.getDynamicMode?
        r.dynamic.push e
        @dynamic_ext[e] = extension
      if extension.getSpecial?
        r.special.push e
        @special_ext[e] = extension

    @extensions[name] = r
    e.activate?(@db) for e in r.all
    new Disposable(=> @remove(name))

  getStatic: (inh, sobj) ->
    sobj.is_static = true
    for k in Object.keys(@static_ext)
      if (m = @static_ext[k].getStaticMode inh, sobj)?
        return m
    return null

  getStaticNames: ->
    m = []
    for k in Object.keys(@static_ext)
      if (n = @static_ext[k].getStaticNames?())?
        m = m.concat n
    return m

  getDynamic: (inh, sobj) ->
    for k in Object.keys(@dynamic_ext)
      if (m = @dynamic_ext[k].getDynamicMode inh, sobj)?
        return m
    return null

  getSpecial: (inh, sobj) ->
    for k in Object.keys(@special_ext)
      if @special_ext[k].isSpecial inh
        return @special_ext[k].getSpecial inh, sobj
    return null

  isSpecial: (inh) ->
    for k in Object.keys(@special_ext)
      if @special_ext[k].isSpecial inh
        return true
    return false

  isValidMode: (inh) ->
    for k in Object.keys(@extensions)
      for ext in @extensions[k].all
        if ext.isValidMode?(inh)
          return true
    return false

  isStaticMode: (inh) ->
    for k in Object.keys(@static_ext)
      if @static_ext[k].isStaticMode inh
        return true
    return false
