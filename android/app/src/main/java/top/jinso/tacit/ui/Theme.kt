package top.jinso.tacit.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.sp

private val light = lightColorScheme(primary=Color(0xFF3B7468),onPrimary=Color.White,primaryContainer=Color(0xFFE5EFEB),onPrimaryContainer=Color(0xFF274F46),secondaryContainer=Color(0xFFE5EFEB),onSecondaryContainer=Color(0xFF274F46),background=Color(0xFFFBFAF7),onBackground=Color(0xFF1C1B1A),surface=Color(0xFFFBFAF7),onSurface=Color(0xFF1C1B1A),surfaceVariant=Color(0xFFF0EDE7),onSurfaceVariant=Color(0xFF6E6860),outline=Color(0xFFA39D94),surfaceContainerHighest=Color(0xFFF0EDE7),surfaceContainerHigh=Color(0xFFF0EDE7),surfaceContainer=Color(0xFFFBFAF7),secondary=Color(0xFF3B7468),outlineVariant=Color(0xFFE7E3DC),error=Color(0xFF9D2933))
private val dark = darkColorScheme(primary=Color(0xFF7DB8A9),onPrimary=Color(0xFF181716),primaryContainer=Color(0xFF274F46),onPrimaryContainer=Color(0xFFDCEDE7),secondaryContainer=Color(0xFF274F46),onSecondaryContainer=Color(0xFFDCEDE7),background=Color(0xFF181716),onBackground=Color(0xFFF2EFEA),surface=Color(0xFF181716),onSurface=Color(0xFFF2EFEA),surfaceVariant=Color(0xFF211F1D),onSurfaceVariant=Color(0xFFA8A197),outline=Color(0xFF5E5953),surfaceContainerHighest=Color(0xFF2F2C29),surfaceContainerHigh=Color(0xFF211F1D),surfaceContainer=Color(0xFF181716),secondary=Color(0xFF7DB8A9),outlineVariant=Color(0xFF2F2C29),error=Color(0xFFE58A8F))
@Composable fun TacitTheme(content: @Composable ()->Unit) = MaterialTheme(colorScheme=if(isSystemInDarkTheme()) dark else light,typography=Typography(
    headlineMedium=TextStyle(fontSize=24.sp,lineHeight=32.sp,fontFamily=FontFamily.Serif),
    titleLarge=TextStyle(fontSize=18.sp,lineHeight=28.sp),titleMedium=TextStyle(fontSize=18.sp,lineHeight=28.sp),
    bodyLarge=TextStyle(fontSize=16.sp,lineHeight=24.sp),bodyMedium=TextStyle(fontSize=16.sp,lineHeight=24.sp),
    bodySmall=TextStyle(fontSize=12.sp,lineHeight=18.sp),labelLarge=TextStyle(fontSize=16.sp,lineHeight=24.sp),labelMedium=TextStyle(fontSize=12.sp,lineHeight=18.sp),labelSmall=TextStyle(fontSize=12.sp,lineHeight=18.sp)
),content=content)
