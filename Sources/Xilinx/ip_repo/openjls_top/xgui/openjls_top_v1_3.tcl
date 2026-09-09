# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "BITNESS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAX_IMAGE_HEIGHT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAX_IMAGE_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "OUT_WIDTH" -parent ${Page_0}


}

proc update_PARAM_VALUE.BITNESS { PARAM_VALUE.BITNESS } {
	# Procedure called to update BITNESS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.BITNESS { PARAM_VALUE.BITNESS } {
	# Procedure called to validate BITNESS
	return true
}

proc update_PARAM_VALUE.MAX_IMAGE_HEIGHT { PARAM_VALUE.MAX_IMAGE_HEIGHT } {
	# Procedure called to update MAX_IMAGE_HEIGHT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAX_IMAGE_HEIGHT { PARAM_VALUE.MAX_IMAGE_HEIGHT } {
	# Procedure called to validate MAX_IMAGE_HEIGHT
	return true
}

proc update_PARAM_VALUE.MAX_IMAGE_WIDTH { PARAM_VALUE.MAX_IMAGE_WIDTH } {
	# Procedure called to update MAX_IMAGE_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAX_IMAGE_WIDTH { PARAM_VALUE.MAX_IMAGE_WIDTH } {
	# Procedure called to validate MAX_IMAGE_WIDTH
	return true
}

proc update_PARAM_VALUE.OUT_WIDTH { PARAM_VALUE.OUT_WIDTH } {
	# Procedure called to update OUT_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.OUT_WIDTH { PARAM_VALUE.OUT_WIDTH } {
	# Procedure called to validate OUT_WIDTH
	return true
}


proc update_MODELPARAM_VALUE.BITNESS { MODELPARAM_VALUE.BITNESS PARAM_VALUE.BITNESS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.BITNESS}] ${MODELPARAM_VALUE.BITNESS}
}

proc update_MODELPARAM_VALUE.MAX_IMAGE_WIDTH { MODELPARAM_VALUE.MAX_IMAGE_WIDTH PARAM_VALUE.MAX_IMAGE_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAX_IMAGE_WIDTH}] ${MODELPARAM_VALUE.MAX_IMAGE_WIDTH}
}

proc update_MODELPARAM_VALUE.MAX_IMAGE_HEIGHT { MODELPARAM_VALUE.MAX_IMAGE_HEIGHT PARAM_VALUE.MAX_IMAGE_HEIGHT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAX_IMAGE_HEIGHT}] ${MODELPARAM_VALUE.MAX_IMAGE_HEIGHT}
}

proc update_MODELPARAM_VALUE.OUT_WIDTH { MODELPARAM_VALUE.OUT_WIDTH PARAM_VALUE.OUT_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.OUT_WIDTH}] ${MODELPARAM_VALUE.OUT_WIDTH}
}

