modes = require '../lib/service-modes'
db = require '../lib/keymode-db'

describe 'Mode Provider - Service', ->
  mode = null
  disp = null
  deactivated = false

  beforeEach ->
    deactivated = false
    db.activate()
    mode =
      name: 'test'
      modes:
        mode1:
          keymap:
            'atom-text-editor':
              'ctrl-k': 'foo'
        mode2: (op) ->
          keymap:
            'atom-text-editor':
              'ctrl-k': 'foo'
        '.mode3':
          keymap:
            'atom-text-editor':
              'ctrl-k': 'bar'
    spyOn(db, 'scheduleReload')
    spyOn(db, 'addCommands')
    disp = modes.consume mode
    expect(db.scheduleReload).toHaveBeenCalled()

  afterEach ->
    unless deactivated
      expect(modes.smodes['mode1']).toEqual mode.modes.mode1
      expect(modes.dmodes['mode2']).toEqual mode.modes.mode2
      expect(modes.smodes['.mode3']).toEqual mode.modes['.mode3']
      disp.dispose()
      expect(modes.smodes['mode1']).toBe null
      expect(modes.dmodes['mode2']).toBe null
      expect(modes.smodes['.mode3']).toBe null
      db.deactivate()
      deactivated = true

  describe 'Test validMode', ->
    it 'valid static', ->
      expect(modes.isValidMode 'mode1').toBe true
      expect(modes.isValidMode '.mode3').toBe true
    it 'valid dynamic', ->
      expect(modes.isValidMode '+mode2').toBe true
    it 'invalid', ->
      expect(modes.isValidMode 'foobar').toBe false

  describe 'Test getStaticMode', ->
    it 'valid static', ->
      expect(modes.getStaticMode 'mode1', {}).toEqual
        keymap:
          'atom-text-editor':
            'ctrl-k': 'foo'
    it 'invalid static', ->
      expect(modes.getStaticMode 'mode2', {}).toBeUndefined()

  describe 'Test getStaticNames', ->
    it 'returns mode1', ->
      expect(modes.getStaticNames()).toEqual ['mode1', '.mode3']

  describe 'Test getDynamicMode', ->
    it 'valid dynamic', ->
      expect(modes.getDynamicMode '+mode2').toEqual
        keymap:
          'atom-text-editor':
            'ctrl-k': 'foo'
    it 'invalid dynamic', ->
      expect(modes.getDynamicMode '+mode3').toBeUndefined()

  describe 'on ::deactivate', ->

    beforeEach ->
      spyOn(modes, 'remove').andCallThrough()
      modes.deactivate()
      deactivated = true

    it 'calls remove', ->
      expect(modes.remove).toHaveBeenCalledWith 'test'

    it 'removes all modes', ->
      expect(modes.dmodes).toBeNull()
      expect(modes.smodes).toBeNull()
      expect(modes.consumed).toBeNull()

    describe 'on dispose after remove', ->
      it 'throws no errors', ->
        expect(-> disp.dispose()).not.toThrow()
