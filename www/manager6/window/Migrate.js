Ext.define('PVE.window.Migrate', {
    extend: 'Ext.window.Window',

    config: {
	vmtype: undefined,
	nodename: undefined,
	vmid: undefined
    },
 // private, used to store the migration mode after checking if the guest runs
    liveMode: undefined,

    controller: {
	xclass: 'Ext.app.ViewController',
	control: {
	    'panel[reference=formPanel]': {
		validityChange: function(panel, isValid) {
		    this.lookup('submitButton').setDisabled(!isValid);
		}
	    },
	    'button[reference=submitButton]': {
		click: function() {
		    var me = this;
		    var view = me.getView();

		    var values = me.lookup('formPanel').getValues();
		    var params = {
			target: values.target
		    };

		    if (values.online) {
			params[view.liveMode] = values.online;
		    }

		    PVE.Utils.API2Request({
			params: params,
			url: '/nodes/' + view.nodename + '/' + view.vmtype + '/' + view.vmid + '/migrate',
			waitMsgTarget: view,
			method: 'POST',
			failure: function(response, opts) {
			    Ext.Msg.alert(gettext('Error'), response.htmlStatus);
			},
			success: function(response, options) {
			    var upid = response.result.data;
			    var extraTitle = Ext.String.format(' ({0} ---> {1})', view.nodename, params.target);

			    Ext.create('PVE.window.TaskViewer', {
				upid: upid,
				extraTitle: extraTitle
			    }).show();

			    view.close();
			}
		    });
		}
	    }
	}
    },

    width: 350,
    modal: true,
    layout: 'auto',
    border: false,
    resizable: false,
    items: [
	{
	    xtype: 'form',
	    reference: 'formPanel',
	    bodyPadding: 10,
	    border: false,
	    fieldDefaults: {
		labelWidth: 100,
		anchor: '100%'
	    },
	    items: [
		{
		    xtype: 'pveNodeSelector',
		    reference: 'pveNodeSelector',
		    name: 'target',
		    fieldLabel: gettext('Target node'),
		    allowBlank: false,
		    disallowedNodes: undefined,
		    onlineValidator: true
		},
		{
		    xtype: 'pvecheckbox',
		    reference: 'onlineToggle',
		    name: 'online',
		    uncheckedValue: 0,
		    defaultValue: 0,
		    checked: false,
		    fieldLabel: gettext('Restart Mode')
		}
		]
	}
    ],
    buttons: [
	{
	    xtype: 'pveHelpButton',
	    reference: 'pveHelpButton',
	    onlineHelp: 'pct_migration',
	    listenToGlobalEvent: false,
	    hidden: false
	},
	'->',
	{
	    xtype: 'button',
	    reference: 'submitButton',
	    text: gettext('Migrate')
	}
    ],

    initComponent : function() {
	var me = this;

	if (!me.nodename) {
	    throw "no node name specified";
	}

	if (!me.vmid) {
	    throw "no VM ID specified";
	}

	if (!me.vmtype) {
	    throw "no VM type specified";
	}

	me.callParent();

	var title = gettext('Migrate') + (' CT ') + me.vmid;
	me.liveMode = 'restart';

	if (me.vmtype === 'qemu') {
	    me.lookup('onlineToggle').setFieldLabel(gettext('Online'));
	    me.lookup('pveHelpButton').setHelpConfig({
		onlineHelp: 'qm_migration'
	    });
	    title = gettext('Migrate') + (' VM ') + me.vmid;
	    me.liveMode = 'online';
	}
	me.setTitle(title);

	var running = false;
	var vmrec = PVE.data.ResourceStore.findRecord('vmid', me.vmid,
	    0, false, false, true);
	if (vmrec && vmrec.data && vmrec.data.running) {
	    running = true;
	}
	me.lookup('onlineToggle').setValue(running);

	me.lookup('pveNodeSelector').disallowedNodes = [me.nodename];
	me.lookup('formPanel').isValid();
    }
});