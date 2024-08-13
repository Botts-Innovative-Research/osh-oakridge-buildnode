/***************************** BEGIN LICENSE BLOCK ***************************

 Copyright (C) 2020 Botts Innovative Research, Inc. All Rights Reserved.
 ******************************* END LICENSE BLOCK ***************************/
package org.sensorhub.node.test;

import org.sensorhub.impl.SensorHub;


public class TestSensorHub
{
    private TestSensorHub()
    {        
    }
    
    public static void main(String[] args)
    {
        SensorHub.main(new String[] {"tools/sensorhub-test/src/main/resources/config.json", "storage"});
    }
}
