--[[---------------------------------------------------------
	Generic selectable-ammunition menu for ACE launchers.

	Stock Derma widgets only (DFrame, DListView, DNumSlider, DComboBox,
	DScrollPanel, DButton) so the window matches the rest of the game's
	panels. Derived weapons provide the preset table and the conversion hooks;
	this file handles layout, clamping mirrors and submission.
-----------------------------------------------------------]]

local MENU_WIDTH = 810
local MENU_HEIGHT = 520
local MARGIN = 10
local LIST_WIDTH = 330
local LIST_HEIGHT = 400
local CONTENT_X = 350
local CONTENT_WIDTH = 450
local CONTENT_TOP = 34
local FOOTER_TOP = 442
local SLIDER_ROW_HEIGHT = 44
local COMBO_ROW_HEIGHT = 28
local BUTTON_WIDTH = 110
local BUTTON_HEIGHT = 28
local SLIDER_PRECISION = 0.001
local STAT_ROWS = 4


local function PrettyUnit( unit )
	if unit == "cm3" then return "cm³" end
	if unit == "x" then return "×" end
	if unit == "deg" then return "°" end
	if unit == "m/s2" then return "m/s²" end

	return unit or ""
end


local function CopyParams( params )
	local copy = { Type = params.Type }

	for key, value in pairs( params ) do
		copy[key] = value
	end

	return copy
end


local function MassParts( mass )
	if mass >= 1 then
		return string.format( "%.2f kg", mass )
	end

	return string.format( "%d g", math.floor( mass * 1000 + 0.5 ) )
end


local function VelocityPart( velocity )
	return string.format( "%d m/s", math.floor( velocity + 0.5 ) )
end


local function ResolveValue( value, data )
	if type( value ) == "function" then
		local ok, result = pcall( value, data )

		return ok and tonumber( result ) or 0
	end

	return tonumber( value ) or 0
end


local function IsPreset( swep, params )
	local def = swep.AmmoDefs[params.Type]
	if not def then return false end

	for key, value in pairs( def.preset ) do
		if type( value ) == "number" then
			if math.abs( ( tonumber( params[key] ) or 0 ) - value ) > SLIDER_PRECISION then
				return false
			end
		elseif tostring( params[key] or "" ) ~= tostring( value ) then
			return false
		end
	end

	return true
end


----------------------------------------------------------------------------
-- Widget helpers
----------------------------------------------------------------------------

local function CreateStatRow( parent, index, width )
	local title = vgui.Create( "DLabel", parent )
	title:SetFont( "DermaDefault" )
	title:SetPos( 0, ( index - 1 ) * 18 )
	title:SetSize( width / 2, 16 )
	title:SetText( "" )

	local value = vgui.Create( "DLabel", parent )
	value:SetFont( "DermaDefault" )
	value:SetPos( width / 2, ( index - 1 ) * 18 )
	value:SetSize( width / 2, 16 )
	value:SetContentAlignment( 6 )
	value:SetText( "" )

	return { title = title, value = value }
end


local function CreateSliderRow( parent, sliderDef, onChange )
	local row = vgui.Create( "DPanel", parent )
	row:SetTall( SLIDER_ROW_HEIGHT )
	row:Dock( TOP )
	row:SetPaintBackground( false )

	local slider = vgui.Create( "DNumSlider", row )
	slider:Dock( TOP )
	slider:SetTall( 22 )
	slider:SetText( sliderDef.title .. ( sliderDef.suffix and ( " (" .. PrettyUnit( sliderDef.suffix ) .. ")" ) or "" ) )
	slider:SetDecimals( sliderDef.decimals or 0 )
	slider:SetMin( 0 )
	slider:SetMax( 1 )
	slider:SetValue( 0 )

	slider.OnValueChanged = function( _, value )
		if slider.ACEIgnore then return end

		onChange( value )
	end

	local info = vgui.Create( "DLabel", row )
	info:Dock( BOTTOM )
	info:SetFont( "DermaDefault" )
	info:SetText( "" )

	row.Slider = slider
	row.Info = info

	row.SetRange = function( self, minValue, maxValue )
		local control = self.Slider
		control.ACEIgnore = true
		control:SetMin( minValue )
		control:SetMax( math.max( maxValue, minValue ) )
		control.ACEIgnore = false
	end

	row.SetValue = function( self, value )
		local control = self.Slider
		control.ACEIgnore = true
		control:SetValue( value )
		control.ACEIgnore = false
	end

	return row
end


local function CreateComboRow( parent, dropdownDef, onChange )
	local row = vgui.Create( "DPanel", parent )
	row:SetTall( COMBO_ROW_HEIGHT )
	row:Dock( TOP )
	row:SetPaintBackground( false )

	local label = vgui.Create( "DLabel", row )
	label:Dock( LEFT )
	label:SetWide( 130 )
	label:SetText( dropdownDef.title )
	label:SetFont( "DermaDefaultBold" )

	local combo = vgui.Create( "DComboBox", row )
	combo:Dock( FILL )
	combo:SetFont( "DermaDefault" )

	for _, option in ipairs( dropdownDef.options ) do
		local optionLabel = dropdownDef.optionLabels and dropdownDef.optionLabels[option] or tostring( option )
		combo:AddChoice( optionLabel, option )
	end

	combo.OnSelect = function( _, _, _, data )
		if not data then return end

		onChange( data )
	end

	row.Combo = combo
	row.Label = label

	--Display-only sync: the parameter is owned by the menu state, so setting
	--the visible text is enough and avoids firing OnSelect in a loop.
	--DComboBox stores its entries as parallel Choices (labels) / Data (values)
	--arrays plus a `selected` index, so mirror that directly.
	row.SetValue = function( self, value )
		for id = 1, #combo.Choices do
			if tostring( combo.Data[id] ) == tostring( value ) then
				combo.selected = id
				combo:SetText( combo.Choices[id] )

				return
			end
		end
	end

	return row
end


----------------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------------

--- Opens the ammunition menu for this weapon, or does nothing when already open.
function SWEP:OpenAmmoMenu()
	if self.AmmoMenuHeldBlock then return end
	if IsValid( self.AmmoMenuFrame ) then return end
	if not self:EnsureAmmoDefs() then return end

	local owner = self:GetOwner()
	if not IsValid( owner ) or not owner:Alive() then return end

	gui.EnableScreenClicker( true )

	local frame = vgui.Create( "DFrame" )
	frame:SetSize( MENU_WIDTH, MENU_HEIGHT )
	frame:Center()
	frame:SetTitle( self.MenuTitle or "Ammunition" )
	frame:SetIcon( "icon16/bomb.png" )
	frame:SetSizable( false )
	frame:SetDraggable( true )
	frame:MakePopup()
	frame:SetDeleteOnClose( true )
	frame:SetKeyboardInputEnabled( true )

	self.AmmoMenuFrame = frame

	--GMod's engine eats Escape before panels see it (it opens the pause menu).
	--While our frame is open, intercept that, close ourselves instead and stop
	--the pause menu from opening. Shift+Escape still bypasses this by design.
	hook.Add( "OnPauseMenuShow", "ACE_AmmoMenu", function()
		if not IsValid( self.AmmoMenuFrame ) then return end

		self:CloseAmmoMenu()

		return false
	end )

	local selectedType = self.AmmoParams and self.AmmoParams.Type or self:GetDefaultAmmoType()

	if not self.AmmoDefs[selectedType] then
		selectedType = self:GetDefaultAmmoType()
	end

	local menu = {
		selected = selectedType,
		params = CopyParams( self.AmmoParams or self:GetPresetParams( selectedType ) ),
		rows = {},
		combos = {},
		stats = {},
		drafts = {},
		ignoreSelect = false,
	}

	frame.OnClose = function()
		self:CloseAmmoMenu()
	end

	frame.OnKeyCodePressed = function( _, key )
		if key == KEY_ESCAPE then
			frame:Close()
		end
	end

	--Preset list
	local headers = self.MenuListHeaders or { "Round", "Speed", "Effect" }
	local list = vgui.Create( "DListView", frame )
	list:SetPos( MARGIN, CONTENT_TOP )
	list:SetSize( LIST_WIDTH, LIST_HEIGHT )
	list:SetMultiSelect( false )

	for _, header in ipairs( headers ) do
		list:AddColumn( header )
	end

	menu.list = list

	for _, ammoType in ipairs( self.AmmoOrder ) do
		local def = self.AmmoDefs[ammoType]
		local params

		if ammoType == menu.selected then
			params = self.AmmoParams
		end

		local first, second = self:GetRowBrief( ammoType, params )
		local line = list:AddLine( def.label, first, second )

		line.AmmoType = ammoType
	end

	list.OwnerWeapon = self

	function list:OnRowSelected( _, line )
		if menu.ignoreSelect then return end

		self.OwnerWeapon:SelectAmmoType( menu, line.AmmoType )
	end

	--Content column
	local content = vgui.Create( "DPanel", frame )
	content:SetPos( CONTENT_X, CONTENT_TOP )
	content:SetSize( CONTENT_WIDTH, LIST_HEIGHT )
	content:SetPaintBackground( false )

	local nameLabel = vgui.Create( "DLabel", content )
	nameLabel:SetFont( "DermaDefaultBold" )
	nameLabel:SetPos( 0, 0 )
	nameLabel:SetSize( CONTENT_WIDTH, 22 )
	nameLabel:SetText( "" )

	local subtitleLabel = vgui.Create( "DLabel", content )
	subtitleLabel:SetFont( "DermaDefault" )
	subtitleLabel:SetPos( 0, 22 )
	subtitleLabel:SetSize( CONTENT_WIDTH, 16 )
	subtitleLabel:SetText( self.MenuSubtitle or "" )

	local blurbLabel = vgui.Create( "DLabel", content )
	blurbLabel:SetFont( "DermaDefault" )
	blurbLabel:SetWrap( true )
	blurbLabel:SetAutoStretchVertical( true )
	blurbLabel:SetPos( 0, 42 )
	blurbLabel:SetSize( CONTENT_WIDTH, 36 )
	blurbLabel:SetText( "" )

	local def = self.AmmoDefs[selectedType]
	local dropdowns = def and def.dropdowns or {}

	local comboTop = 84
	local comboPanel = vgui.Create( "DPanel", content )
	comboPanel:SetPos( 0, comboTop )
	comboPanel:SetSize( CONTENT_WIDTH, math.max( #dropdowns * COMBO_ROW_HEIGHT, 1 ) )
	comboPanel:SetPaintBackground( false )

	for _, dropdownDef in ipairs( dropdowns ) do
		local row = CreateComboRow( comboPanel, dropdownDef, function( value )
			menu.params[dropdownDef.key] = value

			if dropdownDef.rebuild then
				self:RebuildAmmoSliders( menu )
			end

			self:RefreshAmmoMenu( menu )
		end )

		menu.combos[dropdownDef.key] = row
	end

	local statsTop = comboTop + #dropdowns * COMBO_ROW_HEIGHT + 4
	local statsPanel = vgui.Create( "DPanel", content )
	statsPanel:SetPos( 0, statsTop )
	statsPanel:SetSize( CONTENT_WIDTH, STAT_ROWS * 18 )
	statsPanel:SetPaintBackground( false )

	for index = 1, STAT_ROWS do
		menu.stats[index] = CreateStatRow( statsPanel, index, CONTENT_WIDTH )
	end

	local slidersTop = statsTop + STAT_ROWS * 18 + 6
	local sliderScroll = vgui.Create( "DScrollPanel", content )
	sliderScroll:SetPos( 0, slidersTop )
	sliderScroll:SetSize( CONTENT_WIDTH, math.max( LIST_HEIGHT - slidersTop, 40 ) )

	local sliderContainer = vgui.Create( "DListLayout", sliderScroll )
	sliderContainer:Dock( TOP )

	menu.sliderContainer = sliderContainer
	menu.nameLabel = nameLabel
	menu.blurbLabel = blurbLabel

	--Footer
	local status = vgui.Create( "DLabel", frame )
	status:SetFont( "DermaDefaultBold" )
	status:SetPos( MARGIN, FOOTER_TOP + 4 )
	status:SetSize( MENU_WIDTH - MARGIN * 2 - BUTTON_WIDTH * 2 - 20, 20 )
	status:SetText( "" )
	menu.status = status

	local hint = vgui.Create( "DLabel", frame )
	hint:SetFont( "DermaDefault" )
	hint:SetPos( MARGIN, FOOTER_TOP + 26 )
	hint:SetSize( MENU_WIDTH - MARGIN * 2 - BUTTON_WIDTH * 2 - 20, 16 )
	hint:SetText( "Esc closes. Changes apply to this weapon only; presets stay editable." )

	local resetButton = vgui.Create( "DButton", frame )
	resetButton:SetText( "Reset preset" )
	resetButton:SetSize( BUTTON_WIDTH, BUTTON_HEIGHT )
	resetButton:SetPos( MENU_WIDTH - MARGIN - BUTTON_WIDTH * 2 - 8, FOOTER_TOP )
	resetButton.DoClick = function()
		menu.drafts[menu.selected] = nil
		menu.params = self:GetPresetParams( menu.selected )
		self:RebuildAmmoSliders( menu )
		self:RefreshAmmoMenu( menu )
	end

	local applyButton = vgui.Create( "DButton", frame )
	applyButton:SetText( "Load round" )
	applyButton:SetSize( BUTTON_WIDTH, BUTTON_HEIGHT )
	applyButton:SetPos( MENU_WIDTH - MARGIN - BUTTON_WIDTH, FOOTER_TOP )
	applyButton.DoClick = function()
		self:SubmitAmmo( menu.params )
		frame:Close()
	end

	self.AmmoMenu = menu
	self:RebuildAmmoSliders( menu )
	self:RefreshAmmoMenu( menu )

	--Select the loaded round without triggering the click handler.
	menu.ignoreSelect = true

	for _, line in ipairs( list:GetLines() ) do
		if line.AmmoType == menu.selected then
			list:SelectItem( line )
		end
	end

	menu.ignoreSelect = false
end


--- Selects a preset in the editor, keeping unsaved edits per preset.
-- @param menu table Menu state.
-- @param ammoType string Preset id.
function SWEP:SelectAmmoType( menu, ammoType )
	if not self.AmmoDefs[ammoType] then return end

	if menu.selected and menu.selected ~= ammoType then
		menu.drafts[menu.selected] = CopyParams( menu.params )
	end

	menu.selected = ammoType

	local draft = menu.drafts[ammoType]

	if draft then
		menu.params = CopyParams( draft )
	elseif ammoType == ( self.AmmoParams and self.AmmoParams.Type ) then
		menu.params = CopyParams( self.AmmoParams )
	else
		menu.params = self:GetPresetParams( ammoType )
	end

	self:RebuildAmmoSliders( menu )
	self:RefreshAmmoMenu( menu )
end


--- Rebuilds the slider rows for the selected preset.
-- @param menu table Menu state.
function SWEP:RebuildAmmoSliders( menu )
	menu.sliderContainer:Clear()
	menu.rows = {}

	local def = self.AmmoDefs[menu.selected] or self.AmmoDefs[self:GetDefaultAmmoType()]

	--Presets may expose the slider list as a function when the set depends on
	--another dropdown (for example HEAT-only parameters).
	local sliderDefs = def.sliders

	if type( sliderDefs ) == "function" then
		sliderDefs = sliderDefs( self, menu.params )
	end

	for _, sliderDef in ipairs( sliderDefs or {} ) do
		local row = CreateSliderRow( menu.sliderContainer, sliderDef, function( value )
			menu.params[sliderDef.key] = value
			self:RefreshAmmoMenu( menu )
		end )

		menu.rows[#menu.rows + 1] = { def = sliderDef, row = row }
	end
end


--- Recomputes the preview data and refreshes every widget.
-- @param menu table Menu state.
function SWEP:RefreshAmmoMenu( menu )
	local params = menu.params
	local data = self:BuildAmmoData( params )

	if not data then return end

	local def = self.AmmoDefs[params.Type] or self.AmmoDefs[self:GetDefaultAmmoType()]

	--The conversion clamps lengths and payloads against the case and the shell
	--walls. Mirror its results back into the editor so the sliders never lie.
	for key, field in pairs( def.clamped or {} ) do
		local value = data[field]

		if type( value ) == "number" then
			params[key] = value
		end
	end

	for _, entry in ipairs( menu.rows ) do
		local sliderDef = entry.def
		local minValue = ResolveValue( sliderDef.min, data )
		local maxValue = ResolveValue( sliderDef.max, data )

		--A zero-width range would divide by zero inside DNumSlider, so widen it.
		if maxValue <= minValue then
			maxValue = minValue + ( ( sliderDef.decimals or 0 ) > 0 and 0.01 or 1 )
		end

		local value = math.Clamp( tonumber( params[sliderDef.key] ) or minValue, minValue, maxValue )

		params[sliderDef.key] = value
		entry.row:SetRange( minValue, maxValue )
		entry.row:SetValue( value )

		local infoText = ""
		if sliderDef.info then
			local ok, result = pcall( sliderDef.info, data, self )
			infoText = ok and tostring( result ) or ""
		end

		entry.row.Info:SetText( infoText )
	end

	for key, row in pairs( menu.combos ) do
		row:SetValue( params[key] )
	end

	local stats = self:GetAmmoStatRows( data, params ) or {}

	for index, stat in ipairs( menu.stats ) do
		local entry = stats[index] or { title = "", value = "" }
		stat.title:SetText( entry.title or "" )
		stat.value:SetText( entry.value or "" )
	end

	menu.nameLabel:SetText( def.name or def.label or "" )
	menu.blurbLabel:SetText( def.blurb or "" )

	local preset = IsPreset( self, params )
	local detail = ""

	if def.summary then
		local ok, result = pcall( def.summary, self, data, params )
		detail = ok and tostring( result ) or ""
	end

	menu.status:SetText( string.format( "%s  -  %s  %s", def.label or params.Type,
		preset and "preset" or "custom", detail ) )
end


--- Sends the edited selection to the server so it becomes the loaded round.
-- @param params table Parameters to load.
function SWEP:SubmitAmmo( params )
	local ok, json = pcall( util.TableToJSON, params )
	if not ok or type( json ) ~= "string" then return end

	net.Start( self.AmmoNetChannel )
	net.WriteEntity( self )
	net.WriteString( params.Type )
	net.WriteString( json )
	net.SendToServer()
end


--- Closes the ammunition menu if it is open.
function SWEP:CloseAmmoMenu()
	local frame = self.AmmoMenuFrame

	self.AmmoMenuFrame = nil
	self.AmmoMenu = nil
	self.AmmoMenuHeldBlock = false

	--Reload() is called every tick while the key is held. Block reopening until
	--the player releases it, otherwise Esc would instantly re-open the menu.
	local owner = self:GetOwner()

	if IsValid( owner ) and owner:KeyDown( IN_RELOAD ) then
		self.AmmoMenuHeldBlock = true
	end

	if IsValid( frame ) then
		frame:Remove()
	end

	hook.Remove( "OnPauseMenuShow", "ACE_AmmoMenu" )
	gui.EnableScreenClicker( false )
end
