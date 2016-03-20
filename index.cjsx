{_, $, $$, React, ReactBootstrap} = window
{Grid, Input, Col, Row, Button} = ReactBootstrap
{config, POI_VERSION} = window

proxy = require './proxy'

if POI_VERSION.match(/^[0-5]\./) && config.get('plugin.iwukkp.enable', true)
  proxy.start()

module.exports =
  pluginDidLoad: (e) ->
    proxy.start()
  pluginWillUnload: (e) ->
    proxy.stop()
  name: 'iwukkp'
  priority: 794
  displayName: <span><FontAwesome name='eye' /> IWUKKP</span>
  description: 'Hack as much as the author needs.'
  author: 'Gizeta'
  link: 'https://github.com/Gizeta'
  version: '0.2.0'
  show: false
  settingsClass: React.createClass
    getInitialState: ->
      enableKcsp: config.get 'plugin.iwukkp.kcsp.enabled', false
      kcspHost: config.get 'plugin.iwukkp.kcsp.host', ''
      kcspPort: config.get 'plugin.iwukkp.kcsp.port', ''
      modifyGraph: config.get 'plugin.iwukkp.shipgraph.enable', false
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
    handleModifyGraph: ->
      {modifyGraph} = @state
      config.set 'plugin.iwukkp.shipgraph.enable', !modifyGraph
      @setState
        modifyGraph: !modifyGraph
    render: ->
      <div className="form-group">
        <Grid>
          <Row>
            <Col xs={6}>
              <Input type="text" placeholder="kcsp服务器地址" value={@state?.kcspHost} onChange={@handleKcspHostChange} />
            </Col>
            <Col xs={6}>
              <Input type="text" placeholder="端口" value={@state?.kcspPort} onChange={@handleKcspPortChange} />
            </Col>
          </Row>
          <Row>
            <Col xs={6}>
              <Button bsStyle={if @state.enableKcsp then 'success' else 'danger'} onClick={@handleSetKcspEnabled} style={width: '100%'}>
                {if @state.enableKcsp then '√ ' else ''}开启防猫
              </Button>
            </Col>
          </Row>
          <Row style={{ marginTop: 7 }}>
            <Col xs={6}>
              <Button bsStyle={if @state.modifyGraph then 'success' else 'danger'} onClick={@handleModifyGraph} style={width: '100%'}>
                {if @state.modifyGraph then '√ ' else ''}开启立绘坐标魔改
              </Button>
            </Col>
          </Row>
        </Grid>
      </div>
