{_, $, $$, React, ReactBootstrap} = window
{Grid, Input, Col, Button} = ReactBootstrap
{config} = window

if config.get('plugin.iwukkp.enable', true)
  window.proxy = require './proxy'

module.exports =
  name: 'iwukkp'
  priority: 794
  displayName: <span><FontAwesome name='eye' /> IWUKKP</span>
  description: 'i want to use kancollecacher and kcsp on poi'
  author: 'Gizeta'
  link: 'https://github.com/Gizeta'
  version: '0.1.0'
  show: false
  settingsClass: React.createClass
    getInitialState: ->
      enableKcsp: config.get 'plugin.iwukkp.kcsp.enabled', false
      kcspHost: config.get 'plugin.iwukkp.kcsp.host', ''
      kcspPort: config.get 'plugin.iwukkp.kcsp.port', ''
    handleSetKcspEnabled: ->
      {enableKcsp} = @state
      config.set 'plugin.iwukkp.kcsp.enabled', !enableKcsp
      @setState
        enableKcsp: !enableKcsp
    handleKcspHostChange: (e) ->
      value = e.target.value
      config.set 'plugin.iwukkp.kcsp.host', value
      @setState
        kcspHost: value
    handleKcspPortChange: (e) ->
      value = e.target.value
      config.set 'plugin.iwukkp.kcsp.port', value
      @setState
        kcspPort: value
    render: ->
      <div className="form-group">
        <Grid>
          <Col xs={6}>
            <Input type="text" label="kcsp服务器地址" placeholder="地址" value={@state?.kcspHost} onChange={@handleKcspHostChange} />
          </Col>
          <Col xs={6}>
            <Input type="text" label="端口" placeholder="端口" value={@state?.kcspPort} onChange={@handleKcspPortChange} />
          </Col>
          <Col xs={6}>
            <Button bsStyle={if @state.enableKcsp then 'success' else 'danger'} onClick={@handleSetKcspEnabled} style={width: '100%'}>
              {if @state.enableKcsp then '√ ' else ''}开启防猫
            </Button>
          </Col>
        </Grid>
      </div>
